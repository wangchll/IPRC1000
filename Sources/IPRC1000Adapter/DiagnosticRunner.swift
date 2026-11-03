import Foundation
import IOKit.hid

struct ExclusiveDiagnosticWindow {
    private let waitingDeadline: TimeInterval
    private(set) var captureDeadline: TimeInterval?
    private var releaseDeadline: TimeInterval?

    init(start: TimeInterval) { waitingDeadline = start + 900 }

    mutating func keyboard(_ report: [UInt8], at now: TimeInterval) {
        if HIDReportParser.rawUsages(from: report).contains(RemoteKey.microphone.rawValue) {
            if captureDeadline == nil { captureDeadline = now + 120 }
            releaseDeadline = nil
        } else if captureDeadline != nil, releaseDeadline == nil {
            releaseDeadline = now + 2
        }
    }

    func expired(at now: TimeInterval) -> Bool {
        now >= min(captureDeadline ?? waitingDeadline, releaseDeadline ?? .infinity)
    }
}

@MainActor
enum DiagnosticRunner {
    static func runExclusive(address: String? = nil) -> Int32 {
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else {
            write("Input Monitoring is not granted to this diagnostic. Authorize it as the logged-in user before administrator execution.")
            return 77
        }
        let input = DeviceVoiceInput(expectedAddress: address)
        input.onStatus = { message, _ in write(message) }
        var window = ExclusiveDiagnosticWindow(start: ProcessInfo.processInfo.systemUptime)
        input.onIsolation = { ready in
            write("EXCLUSIVE: \(ready)")
        }
        input.onAudioAvailable = { ready in write("F7 AVAILABLE: \(ready)") }
        // Counts only: this diagnostic never synthesizes keys or routes audio.
        var keys = 0
        var frames = 0
        input.onKeyboard = { report in
            window.keyboard(report, at: ProcessInfo.processInfo.systemUptime)
            keys += 1
            write("TARGET KEYBOARD REPORTS: \(keys)")
        }
        input.onReport = { _, _ in
            frames += 1
            if frames == 1 || frames % 50 == 0 { write("TARGET F7 FRAMES: \(frames)") }
        }
        input.start()
        while !window.expired(at: ProcessInfo.processInfo.systemUptime) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        input.stop()
        write("Exclusive diagnostic ended: keyboard=\(keys) F7=\(frames)")
        return frames > 0 ? 0 : 2
    }

    static func run() -> Int32 {
        let voice = VoiceController()
        let hid = HIDController()
        hid.onStatus = { message, ready in
            write("HID \(ready ? "READY" : "WAIT"): \(message)")
        }
        hid.onInputDiagnostics = { message in write("INPUT: \(message)") }
        hid.onVoiceReport = { report, reportID in voice.receive(report, reportID: reportID) }
        hid.onVoiceConnection = { ready in voice.connectionChanged(ready) }
        voice.onStatus = { message, ready in
            write("VOICE \(ready ? "READY" : "WAIT"): \(message)")
        }
        voice.onLevel = { level in
            if level > 0.01 { write("VOICE LEVEL: \(level)") }
        }
        voice.start()
        hid.start()
        withExtendedLifetime(hid) {
            RunLoop.main.run(until: Date().addingTimeInterval(6))
        }
        return 0
    }

    nonisolated private static func write(_ message: String) {
        FileHandle.standardOutput.write(Data("\(message)\n".utf8))
    }
}
