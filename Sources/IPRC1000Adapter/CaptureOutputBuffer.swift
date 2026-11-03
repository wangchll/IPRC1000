import Darwin
import Foundation

/// A busy foreground app must not cause the target keyboard owner to exit.
struct CaptureOutputBuffer {
    private var pending = Data()
    private var offset = 0
    var queuedBytes: Int { pending.count - offset }

    mutating func append(_ line: String, audio: Bool = false) -> Bool {
        let data = Data((line + "\n").utf8)
        if audio && queuedBytes + data.count > 262144 { return true }
        guard queuedBytes + data.count <= 1048576 else { return false }
        if offset > 0 { pending.removeFirst(offset); offset = 0 }
        pending.append(data)
        return true
    }

    mutating func flush(to descriptor: Int32) -> Bool {
        while offset < pending.count {
            let start = offset
            let count = pending.count - start
            let written = pending.withUnsafeBytes {
                Darwin.write(descriptor, $0.baseAddress!.advanced(by: start), count)
            }
            if written < 0 {
                let error = errno
                if error == EINTR { continue }
                if error == EAGAIN || error == EWOULDBLOCK { return true }
                return false
            }
            guard written > 0 else { return false }
            offset += written
        }
        pending.removeAll(keepingCapacity: true)
        offset = 0
        return true
    }
}
