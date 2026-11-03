import CRemoteSupport
import Darwin
import Foundation
import IOBluetooth
import os

/// The privileged process owns only the target HID. The broad HCI stream stays
/// inside this process and only validated target F7 frames cross the pipe.
@MainActor
enum TemporaryVoiceCapture {
    private static let logger = Logger(subsystem: "local.iprc1000.adapter", category: "CaptureLifecycle")
    static func run(address: String) -> Int32 {
        guard geteuid() == 0, setuid(0) == 0,
              address.count == 12, address.allSatisfy({ $0.isHexDigit }) else { return 77 }
        guard iprc_hci_tool_valid() != 0 else {
            print("ERROR Apple PacketLogger 签名校验失败"); return 77
        }
        guard IOHIDAccess.granted else {
            print("ERROR 适配器缺少输入监控授权，请在系统设置中检查 IPRC1000 Adapter"); return 77
        }
        signal(SIGPIPE, SIG_IGN)
        var child: Process?
        var reader: FileHandle?
        var nextStart = 0.0
        var failures = 0
        func stopAudio() {
            if let child {
                if child.isRunning { child.terminate() }
                let deadline = ProcessInfo.processInfo.systemUptime + 1
                while child.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(10000) }
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
                child.waitUntilExit()
            }
            try? reader?.close()
            reader = nil; child = nil
        }
        _ = fcntl(STDIN_FILENO, F_SETFL, fcntl(STDIN_FILENO, F_GETFL) | O_NONBLOCK)
        let keys = DeviceVoiceInput(expectedAddress: address)
        var alive = true
        var exitReason = "outbound control queue exceeded limit"
        var isolated = false
        var heldReport: [UInt8] = []
        var outbound = CaptureOutputBuffer()
        _ = fcntl(STDOUT_FILENO, F_SETFL, fcntl(STDOUT_FILENO, F_GETFL) | O_NONBLOCK)
        func send(_ line: String) {
            if !outbound.append(line, audio: line.hasPrefix("F ")) { alive = false }
        }
        keys.onIsolation = { ready in
            isolated = ready
            if !ready { heldReport = [] }
            send(ready ? "I 1" : "I 0")
        }
        keys.onStatus = { message, _ in send("S " + message.replacingOccurrences(of: "\n", with: " ")) }
        keys.onKeyboard = { report in
            heldReport = report
            guard isolated else { return }
            if child == nil && HIDReportParser.rawUsages(from: report).contains(RemoteKey.microphone.rawValue) { return }
            send("K " + report.map { String(format: "%02X", $0) }.joined())
        }
        var pending = BoundedCaptureLines()
        var watermark = HCIFrameWatermark()
        var bytes = [UInt8](repeating: 0, count: 65536)
        keys.start()
        defer { keys.stop(); stopAudio() }
        send("READY")
        while alive {
            var byte: UInt8 = 0
            let control = read(STDIN_FILENO, &byte, 1)
            if control == 0 { exitReason = "foreground pipe EOF"; break }
            if control > 0 {
                guard byte == 82 else { exitReason = "invalid control byte"; break } // R: retry audio only, never execute a command.
                logger.notice("audio retry requested; target HID ownership retained")
                send("A 0")
                stopAudio()
                pending = BoundedCaptureLines()
                nextStart = ProcessInfo.processInfo.systemUptime
                continue
            }
            if control < 0 && errno != EAGAIN && errno != EINTR { exitReason = "control pipe error"; break }
            if child == nil && ProcessInfo.processInfo.systemUptime >= nextStart {
                guard iprc_hci_tool_valid() != 0 else { send("ERROR Apple PacketLogger 签名校验失败"); break }
                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: "/Applications/PacketLogger.app/Contents/Resources/packetlogger")
                process.arguments = watermark.canResumeBuffered
                    ? ["convert", "-b", "-s", "-f", "itpanhsr"]
                    : ["convert", "-s", "-f", "itpanhsr"]
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    child = process; reader = pipe.fileHandleForReading
                    let fd = reader!.fileDescriptor
                    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                    send("S HCI 音频捕获已启动；目标按键独占保持")
                    if isolated && HIDReportParser.rawUsages(from: heldReport).contains(RemoteKey.microphone.rawValue) {
                        send("K " + heldReport.map { String(format: "%02X", $0) }.joined())
                    }
                } catch {
                    failures += 1
                    nextStart = ProcessInfo.processInfo.systemUptime + min(30, pow(2, Double(min(failures, 7))) * 0.125)
                    send("S HCI 音频启动失败，保留按键独占并等待重试")
                }
            }
            if let reader, let process = child {
                let count = read(reader.fileDescriptor, &bytes, bytes.count)
                if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) || (!process.isRunning && count < 0) {
                    logger.notice("audio process ended; restarting without releasing target HID")
                    send("A 0")
                    stopAudio()
                    pending = BoundedCaptureLines()
                    failures += 1
                    nextStart = ProcessInfo.processInfo.systemUptime + min(30, pow(2, Double(min(failures, 7))) * 0.125)
                    send("S HCI 音频中断，目标按键保持独占，正在恢复")
                } else if count > 0 {
                    for line in pending.append(Data(bytes.prefix(count))) {
                        guard isolated, let frame = HCIVoiceLine.parse(line, address: address), frame.report.first == 0xF7 else { continue }
                        let timestamp = String(line.prefix(while: { $0 != "\t" }))
                        guard watermark.accept(timestamp: timestamp, handle: frame.handle, report: frame.report) else { continue }
                        failures = 0
                        send("F \(frame.handle) " + Data(frame.report).base64EncodedString())
                    }
                }
            }
            if !outbound.flush(to: STDOUT_FILENO) {
                exitReason = "foreground pipe write failed errno=\(errno)"
                break
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        logger.notice("temporary capture ending: \(exitReason, privacy: .public)")
        return 0
    }
}

import IOKit.hid
private enum IOHIDAccess {
    static var granted: Bool { IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted }
}
