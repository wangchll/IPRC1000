import AVFoundation
import Speech

/// Final results can arrive after the next utterance starts, or out of order.
struct SpeechSegments {
    private var next = 0
    private var order: [Int] = []
    private var completed: [Int: String] = [:]
    private(set) var current: Int?

    mutating func begin() -> Int {
        next += 1
        current = next
        order.append(next)
        return next
    }

    mutating func endInput() { current = nil }

    mutating func complete(_ id: Int, text: String) -> [(Int, String)] {
        guard order.contains(id), completed[id] == nil else { return [] }
        if current == id { current = nil }
        completed[id] = text
        var ready: [(Int, String)] = []
        while let first = order.first, let text = completed.removeValue(forKey: first) {
            order.removeFirst()
            ready.append((first, text))
        }
        return ready
    }
}

/// Let normal paste and clipboard restoration finish before committing another final.
@MainActor
final class SpeechCommitQueue {
    private var pending: [() -> Void] = []
    private var busy = false

    func append(_ commit: @escaping () -> Void) {
        pending.append(commit)
        runNext()
    }

    func clear() {
        pending.removeAll()
    }

    private func runNext() {
        guard !busy, !pending.isEmpty else { return }
        busy = true
        pending.removeFirst()()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
            guard let self else { return }
            self.busy = false
            self.runNext()
        }
    }
}

@MainActor
final class VoiceTranscription {
    var onText: (String) -> Void = { _ in }
    var onStatus: (String) -> Void = { _ in }
    var onBegin: () -> (String) -> Void = { { _ in } }
    var onEnabled: (Bool) -> Void = { _ in }
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    private var enabled = false
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var tasks: [Int: SFSpeechRecognitionTask] = [:]
    private var commits: [Int: (String) -> Void] = [:]
    private let commitQueue = SpeechCommitQueue()
    private var segments = SpeechSegments()
    private var generation = 0

    func enable() {
        generation += 1
        let authorizationSession = generation
        onStatus("等待语音识别授权；仅使用本机识别")
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self, self.generation == authorizationSession else { return }
                guard status == .authorized else {
                    self.onStatus("语音识别未授权")
                    return
                }
                guard self.recognizer?.supportsOnDeviceRecognition == true else {
                    self.onStatus("本机中文识别模型不可用；请先在系统中下载中文听写语言")
                    return
                }
                self.enabled = true
                self.onEnabled(true)
                self.onStatus("本机中文转写已就绪，等待遥控器语音")
            }
        }
    }

    func append(_ samples: [Int16]) {
        guard enabled, recognizer?.isAvailable == true, !samples.isEmpty else { return }
        if request == nil {
            let epoch = generation
            let session = segments.begin()
            commits[session] = onBegin()
            let next = SFSpeechAudioBufferRecognitionRequest()
            next.requiresOnDeviceRecognition = true
            next.shouldReportPartialResults = true
            request = next
            onText("")
            onStatus("正在转写遥控器语音…")
            tasks[session] = recognizer?.recognitionTask(with: next) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let final = result?.isFinal == true
                let message = error?.localizedDescription
                DispatchQueue.main.async {
                    guard let self, self.enabled, self.generation == epoch,
                          self.tasks[session] != nil else { return }
                    if let text { self.onText(text) }
                    if final || message != nil {
                        if self.segments.current == session { self.request = nil }
                        self.tasks.removeValue(forKey: session)
                        for (id, result) in self.segments.complete(session, text: final ? text ?? "" : "") {
                            let commit = self.commits.removeValue(forKey: id)
                            if !result.isEmpty, let commit {
                                self.commitQueue.append { commit(result) }
                            }
                        }
                        self.onStatus(message.map { "转写：\($0)" } ?? "转写完成")
                    }
                }
            }
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(samples.count)),
              let data = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = UInt32(samples.count)
        for index in samples.indices { data[index] = Float(samples[index]) / 32768 }
        request?.append(buffer)
    }

    func finish() {
        request?.endAudio()
        request = nil
        segments.endInput()
    }

    func disable() {
        enabled = false
        generation += 1
        request?.endAudio()
        request = nil
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        commits.removeAll()
        commitQueue.clear()
        segments = SpeechSegments()
        onEnabled(false)
    }
}
