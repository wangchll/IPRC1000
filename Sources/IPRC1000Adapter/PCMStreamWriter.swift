import Darwin
import Foundation

/// Bounded, cancellable writes to one audio helper. Never closes a reused fd.
final class PCMStreamWriter: @unchecked Sendable {
    static let capacity = 16_000 * 2 * 5
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "local.iprc1000.pcm-writer")
    private let lock = NSLock()
    private let onFailure: @Sendable (String) -> Void
    private var queuedBytes = 0
    private var ending = false
    private var cancelled = false
    private var closed = false // Accessed only on queue.

    init(_ handle: FileHandle, onFailure: @escaping @Sendable (String) -> Void) throws {
        self.handle = handle; self.onFailure = onFailure
        let fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(fd, F_SETNOSIGPIPE, 1) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    @discardableResult func append(_ data: Data) -> Bool {
        guard !data.isEmpty else { return true }
        lock.lock()
        guard !ending, !cancelled, data.count <= Self.capacity - queuedBytes else {
            lock.unlock(); return false
        }
        queuedBytes += data.count
        queue.async {
            let error = self.write(data)
            self.lock.lock()
            self.queuedBytes -= data.count
            let report = error != nil && !self.cancelled
            if report { self.cancelled = true; self.ending = true }
            self.lock.unlock()
            if report {
                self.close()
                self.onFailure(error!)
            }
        }
        lock.unlock()
        return true
    }

    func finish() {
        lock.lock()
        guard !ending else { lock.unlock(); return }
        ending = true
        queue.async { self.close() }
        lock.unlock()
    }

    func cancel() {
        lock.lock(); cancelled = true; ending = true
        queue.async { self.close() }
        lock.unlock()
    }

    private func write(_ data: Data) -> String? {
        let end = ProcessInfo.processInfo.systemUptime + 2
        return data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return nil }
            var offset = 0
            while offset < bytes.count {
                lock.lock(); let abort = cancelled; lock.unlock()
                if abort { return nil }
                if ProcessInfo.processInfo.systemUptime >= end { return "PCM pipe stalled" }
                let count = Darwin.write(handle.fileDescriptor, base.advanced(by: offset), bytes.count - offset)
                if count > 0 { offset += count; continue }
                if count < 0 && errno == EINTR { continue }
                guard count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) else {
                    return "PCM pipe write failed errno=\(errno)"
                }
                var item = pollfd(fd: handle.fileDescriptor, events: Int16(POLLOUT), revents: 0)
                if poll(&item, 1, 50) < 0 && errno != EINTR { return "PCM pipe poll failed errno=\(errno)" }
            }
            return nil
        }
    }

    private func close() {
        guard !closed else { return }
        closed = true
        try? handle.close()
    }
}
