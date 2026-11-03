import Foundation

/// Replays 16 kHz mono PCM through the production streaming session, without HCI capture.
@MainActor
enum WeChatReplay {
    static func run(path: String, rapid: Bool = false, secondPath: String? = nil) -> Int32 {
        guard let pcm = try? Data(contentsOf: URL(fileURLWithPath: path)),
              !pcm.isEmpty, pcm.count.isMultiple(of: 2) else {
            print("Expected nonempty Int16LE mono PCM at 16 kHz")
            return 1
        }
        var clips = [pcm]
        if rapid {
            let next = secondPath.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) } ?? (secondPath == nil ? pcm : Data())
            guard !next.isEmpty, next.count.isMultiple(of: 2) else {
                print("Invalid second PCM clip")
                return 1
            }
            clips.append(next)
        }
        let session = ExternalVoiceInput()
        session.onStatus = { print($0) }
        print("Replay begins in 8 seconds; focus the target text field")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 8))
        for clip in clips {
            print(session.begin(shortcut: .modifierOnly([.function]), toggle: false))
            guard session.active else { return 1 }
            for offset in stride(from: 0, to: clip.count, by: 640) {
                let end = min(offset + 640, clip.count)
                let samples = stride(from: offset, to: end, by: 2).map {
                    Int16(bitPattern: UInt16(clip[$0]) | UInt16(clip[$0 + 1]) << 8)
                }
                session.append(samples)
                RunLoop.main.run(until: Date(timeIntervalSinceNow: Double(samples.count) / 16_000))
            }
            session.finish()
        }
        let deadline = Date(timeIntervalSinceNow: 30)
        while session.active && Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        }
        print(session.active ? "Replay timed out" : "Replay ended; verify text in target editor")
        return session.active ? 2 : 0
    }
}
