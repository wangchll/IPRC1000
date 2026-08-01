import Foundation

@MainActor
enum DiagnosticRunner {
    static func run() -> Int32 {
        let voice = VoiceController()
        voice.onStatus = { message, ready in
            write("VOICE \(ready ? "READY" : "WAIT"): \(message)")
        }
        voice.onLevel = { level in
            if level > 0.01 { write("VOICE LEVEL: \(level)") }
        }
        voice.start()
        RunLoop.main.run(until: Date().addingTimeInterval(6))
        return 0
    }

    nonisolated private static func write(_ message: String) {
        FileHandle.standardOutput.write(Data("\(message)\n".utf8))
    }
}
