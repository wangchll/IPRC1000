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
        guard IOHIDAccess.granted else {
            print("ERROR 适配器缺少输入监控授权，请在系统设置中检查 IPRC1000 Adapter"); return 77
        }
        signal(SIGPIPE, SIG_IGN)
        var capture: IPRCNativeCaptureRef?
        var nextStart = 0.0
        var nextDiagnostics = 0.0
        var lastDiagnostics = ""
        var failures = 0
        var audioRequested = false
        var traceLease: ScopedHCITraceLease?
        func stopAudio() {
            if let capture { iprc_native_capture_destroy(capture) }
            capture = nil
        }
        _ = fcntl(STDIN_FILENO, F_SETFL, fcntl(STDIN_FILENO, F_GETFL) | O_NONBLOCK)
        let keys = DeviceVoiceInput(expectedAddress: address)
        var alive = true
        var exitReason = "outbound control queue exceeded limit"
        var isolated = false
        var keyboardReports = 0
        var microphoneHeld = false
        var heldReport: [UInt8] = []
        var outbound = CaptureOutputBuffer()
        _ = fcntl(STDOUT_FILENO, F_SETFL, fcntl(STDOUT_FILENO, F_GETFL) | O_NONBLOCK)
        func send(_ line: String) {
            if !outbound.append(line, audio: line.hasPrefix("F ")) { alive = false }
        }
        keys.onIsolation = { ready in
            isolated = ready
            logger.notice("target HID isolation=\(ready, privacy: .public)")
            if !ready { heldReport = [] }
            send(ready ? "I 1" : "I 0")
        }
        keys.onStatus = { message, _ in send("S " + message.replacingOccurrences(of: "\n", with: " ")) }
        keys.onKeyboard = { report in
            heldReport = report
            keyboardReports += 1
            let held = HIDReportParser.rawUsages(from: report).contains(RemoteKey.microphone.rawValue)
            if held != microphoneHeld {
                microphoneHeld = held
                logger.notice("target microphone held=\(held, privacy: .public) keyboardReports=\(keyboardReports, privacy: .public) isolated=\(isolated, privacy: .public) nativeActive=\(capture != nil, privacy: .public)")
            }
            guard isolated else { return }
            if audioRequested && capture == nil && HIDReportParser.rawUsages(from: report).contains(RemoteKey.microphone.rawValue) { return }
            send("K " + report.map { String(format: "%02X", $0) }.joined())
        }
        var report = [UInt8](repeating: 0, count: 652)
        keys.start()
        defer { keys.stop(); stopAudio(); traceLease?.stop() }
        send("M 0")
        send("READY")
        while alive {
            var byte: UInt8 = 0
            let control = read(STDIN_FILENO, &byte, 1)
            if control == 0 { exitReason = "foreground pipe EOF"; break }
            if control > 0 {
                guard let command = CaptureCommand(rawValue: byte) else { exitReason = "invalid control byte"; break }
                logger.notice("capture control=\(command.rawValue, privacy: .public); target HID retained")
                switch command {
                case .startAudio, .startScopedAudio:
                    if command == .startAudio, audioRequested, traceLease != nil { continue }
                    send("A 0")
                    stopAudio()
                    traceLease?.stop(); traceLease = nil
                    do {
                        let lease = ScopedHCITraceLease()
                        let session = command == .startAudio
                        try lease.start(session: session)
                        traceLease = lease
                        audioRequested = true
                        failures = 0
                        nextStart = ProcessInfo.processInfo.systemUptime
                        send("M 1")
                        send(session ? "S 蓝牙语音输入已启用；停止语音或退出后恢复配置，按键接管保留" : "S 限时原生验证已开启：保留认证、不写 HCI 抓包文件；5分钟后恢复")
                    } catch {
                        audioRequested = false
                        send("M 0")
                        if case HCITraceConfiguration.Failure.managedPreferences = error {
                            send("S 系统描述文件正在强制蓝牙诊断设置，已拒绝启动；目标按键接管保持")
                        } else {
                            send("S 蓝牙诊断配置未就绪，未启动音频；目标按键接管保持")
                        }
                        logger.error("scoped trace start failed: \(String(describing: error), privacy: .public)")
                    }
                case .stopAudio:
                    audioRequested = false
                    failures = 0
                    stopAudio()
                    let restored = traceLease?.stop() ?? true
                    traceLease = nil
                    send("M 0")
                    send(restored ? "S 蓝牙语音已停止；诊断配置已恢复，目标按键独占保持" : "S 蓝牙语音已停止；诊断配置恢复待检查，目标按键独占保持")
                case .retryAudio:
                    if audioRequested {
                        logger.notice("audio retry requested; target HID ownership retained")
                        send("A 0")
                        stopAudio()
                        nextStart = ProcessInfo.processInfo.systemUptime
                    }
                }
                continue
            }
            if control < 0 && errno != EAGAIN && errno != EINTR { exitReason = "control pipe error"; break }
            if let lease = traceLease, lease.expiring || !lease.running {
                send("A 0")
                stopAudio()
                let restored = lease.stop()
                traceLease = nil
                audioRequested = false
                send("M 0")
                send(restored ? "S 限时验证结束，诊断配置已恢复；目标按键独占保持" : "S 限时诊断进程异常结束，配置恢复待检查；目标按键独占保持")
            }
            if audioRequested && capture == nil && ProcessInfo.processInfo.systemUptime >= nextStart {
                let status = iprc_native_capture_create(address, &capture)
                if status == 0 {
                    lastDiagnostics = ""
                    nextDiagnostics = 0
                    send("S 原生音频服务已连接，等待目标F7；目标按键独占保持")
                    if isolated && HIDReportParser.rawUsages(from: heldReport).contains(RemoteKey.microphone.rawValue) {
                        send("K " + heldReport.map { String(format: "%02X", $0) }.joined())
                    }
                } else {
                    failures += 1
                    nextStart = ProcessInfo.processInfo.systemUptime + min(30, pow(2, Double(min(failures, 7))) * 0.125)
                    send("S 原生音频启动失败（\(status)），保留目标按键独占并重试")
                    logger.error("native start failed status=\(status, privacy: .public); HID retained")
                }
            }
            if let capture {
                var handle: UInt16 = 0
                // Keep the bounded target queue intact until HID attachment;
                // a cold connection can deliver F7 before the matching callback.
                for _ in 0..<(isolated ? 64 : 0) {
                    guard iprc_native_capture_read(capture, &report, &handle) != 0 else { break }
                    failures = 0
                    send("F \(handle) " + Data(report).base64EncodedString())
                }
                let now = ProcessInfo.processInfo.systemUptime
                if now >= nextDiagnostics {
                    nextDiagnostics = now + 1
                    var stats = IPRCNativeCaptureStats()
                    iprc_native_capture_stats(capture, &stats)
                    let diagnostics = "authSent=\(stats.authorization_submitted) envelopes=\(stats.envelopes) f7=\(stats.frames) dropped=\(stats.dropped) handle=\(stats.handle) cid=\(stats.interrupt_cid) error=\(stats.error) isolated=\(isolated)"
                    if diagnostics != lastDiagnostics {
                        lastDiagnostics = diagnostics
                        logger.notice("native pipeline \(diagnostics, privacy: .public)")
                        send("S 原生音频：封装 \(stats.envelopes)，F7 \(stats.frames)，丢帧 \(stats.dropped)；按键独占 \(isolated ? "已生效" : "等待目标")")
                    }
                    if stats.error != 0 {
                        send("A 0")
                        stopAudio()
                        if stats.error == IPRCNativeCaptureProfileRequired {
                            audioRequested = false
                            traceLease?.stop(); traceLease = nil
                            send("M 0")
                            send("S 系统拒绝蓝牙音频：Bluetooth Profile Required；目标按键独占保持，语音未就绪")
                        } else {
                            failures += 1
                            nextStart = now + min(30, pow(2, Double(min(failures, 7))) * 0.125)
                            send("S 原生音频连接中断（\(stats.error)），目标按键接管保持，正在恢复")
                        }
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
