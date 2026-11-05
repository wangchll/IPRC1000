/// Retains the start of an utterance until the IME shortcut has taken effect.
struct VoiceWarmup {
    enum Failure: Error { case overflow }
    private enum Phase { case waiting, warming, streaming }
    static let capacity = 16_000 * 5
    private var phase = Phase.waiting
    private var samples: [Int16] = []
    private var finished = false
    var isStreaming: Bool { phase == .streaming }

    mutating func append(_ chunk: [Int16]) throws -> [Int16]? {
        guard !finished else { return nil }
        if phase == .streaming { return chunk }
        guard chunk.count <= Self.capacity - samples.count else { throw Failure.overflow }
        samples.append(contentsOf: chunk)
        return nil
    }
    mutating func helperReady() -> Bool {
        guard phase == .waiting else { return false }
        phase = .warming
        return true
    }
    mutating func release() -> (samples: [Int16], finish: Bool)? {
        guard phase == .warming else { return nil }
        phase = .streaming
        let result = (samples, finished)
        samples.removeAll(keepingCapacity: true)
        return result
    }
    /// Returns whether the input pipe can close now, rather than after warmup.
    mutating func finish() -> Bool {
        finished = true
        return phase == .streaming
    }
}
