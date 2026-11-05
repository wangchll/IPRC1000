import Darwin
import Foundation

final class Result: @unchecked Sendable {
    let lock = NSLock()
    let failed = DispatchSemaphore(value: 0)
    private(set) var errors: [String] = []
    private(set) var accepted = 0
    func error(_ message: String) { lock.lock(); errors.append(message); lock.unlock(); failed.signal() }
    func accept() { lock.lock(); accepted += 1; lock.unlock() }
}

// Draining preserves every byte and closes only after accepted writes.
do {
    let pipe = Pipe(), state = Result()
    let writer = try PCMStreamWriter(pipe.fileHandleForWriting, onFailure: { state.error($0) })
    let first = Data((0..<640).map { UInt8($0 % 251) }), second = Data(repeating: 99, count: 320)
    assert(writer.append(first) && writer.append(second))
    writer.finish()
    assert(pipe.fileHandleForReading.readDataToEndOfFile() == first + second)
    assert(state.errors.isEmpty && !writer.append(first))
}

// A non-reading helper cannot grow memory or hold cancellation behind a write.
do {
    let pipe = Pipe(), state = Result()
    let writer = try PCMStreamWriter(pipe.fileHandleForWriting, onFailure: { state.error($0) })
    assert(writer.append(Data(repeating: 0, count: PCMStreamWriter.capacity)))
    usleep(100_000)
    assert(!writer.append(Data([1])))
    let start = ProcessInfo.processInfo.systemUptime
    writer.cancel()
    let written = pipe.fileHandleForReading.readDataToEndOfFile()
    assert(ProcessInfo.processInfo.systemUptime - start < 1)
    assert(written.count < PCMStreamWriter.capacity && state.errors.isEmpty)
}

// Finish cannot hang indefinitely when the helper stops consuming audio.
do {
    let pipe = Pipe(), state = Result()
    let writer = try PCMStreamWriter(pipe.fileHandleForWriting, onFailure: { state.error($0) })
    assert(writer.append(Data(repeating: 0, count: PCMStreamWriter.capacity)))
    writer.finish()
    assert(state.failed.wait(timeout: .now() + 4) == .success)
    assert(state.errors == ["PCM pipe stalled"])
    _ = pipe.fileHandleForReading.readDataToEndOfFile()
}

// A crashed reader reports EPIPE without killing the app with SIGPIPE.
do {
    let pipe = Pipe(), state = Result()
    let writer = try PCMStreamWriter(pipe.fileHandleForWriting, onFailure: { state.error($0) })
    try pipe.fileHandleForReading.close()
    assert(writer.append(Data(repeating: 0, count: 640)))
    assert(state.failed.wait(timeout: .now() + 3) == .success)
    assert(state.errors.count == 1 && state.errors[0].contains("errno=32"))
}

// Admission and finish are ordered even if called from different threads.
do {
    let pipe = Pipe(), state = Result(), group = DispatchGroup()
    let writer = try PCMStreamWriter(pipe.fileHandleForWriting, onFailure: { state.error($0) })
    for _ in 0..<100 {
        DispatchQueue.global().async(group: group) {
            if writer.append(Data(repeating: 1, count: 640)) { state.accept() }
        }
    }
    DispatchQueue.global().async(group: group) { writer.finish() }
    group.wait()
    writer.finish()
    assert(pipe.fileHandleForReading.readDataToEndOfFile().count == state.accepted * 640)
    assert(state.errors.isEmpty)
}
print("PCM WRITER SELF-TEST PASS: exact drain, bounded backlog, blocked cancellation, stall deadline, EPIPE and concurrent finish")
