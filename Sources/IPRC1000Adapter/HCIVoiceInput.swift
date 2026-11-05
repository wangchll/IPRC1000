import Foundation

/// Uses Apple's decoded HID channel classification, then validates the complete ACL/L2CAP envelope.
/// No byte scanning: a frame must belong to the uniquely paired remote's address and receive channel.
enum HCIVoiceLine {
    static func parse(_ line: String, address: String) -> (report: [UInt8], handle: UInt16)? {
        var fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        if fields.last == "" { fields.removeLast() }
        guard fields.count == 7, fields[1] == "HID Interrupt Receive",
              TargetRemote.normalizedAddress(String(fields[2])) == TargetRemote.normalizedAddress(address),
              TargetRemote.normalizedAddress(address).count == 12,
              fields[4].hasPrefix("0x"), let handle = UInt16(fields[4].dropFirst(2), radix: 16)
        else { return nil }
        let words = fields[6].split(whereSeparator: { $0.isWhitespace })
        guard words.count == 661 || words.count == 18 else { return nil }
        var raw: [UInt8] = []
        raw.reserveCapacity(words.count)
        for word in words {
            guard word.count == 2, let byte = UInt8(word, radix: 16) else { return nil }
            raw.append(byte)
        }
        func u16(_ offset: Int) -> UInt16 { UInt16(raw[offset]) | UInt16(raw[offset + 1]) << 8 }
        let flags = u16(0)
        guard flags & 0x0FFF == handle, flags & 0xC000 == 0,
              [0, 2].contains(Int((flags >> 12) & 3)),
              Int(u16(2)) == raw.count - 4, Int(u16(4)) == raw.count - 8, u16(6) >= 0x0040,
              raw[8] == 0xA1
        else { return nil }
        if raw[9] == 0xF7 {
            guard ClassicVoiceFrame.parse(Array(raw.dropFirst(9)), reportID: 0xF7) != nil else { return nil }
        } else {
            guard raw[9] == 1, raw.count == 18 else { return nil }
        }
        return (Array(raw.dropFirst(9)), handle)
    }
}


import CRemoteSupport
import Darwin
import IOBluetooth
import os
import Security

enum CaptureCommand: UInt8 {
    case startAudio = 65, startScopedAudio = 68, retryAudio = 82, stopAudio = 83
}

enum CaptureFailure {
    static func message(_ code: Int32) -> String {
        switch code {
        case -1001: "未找到 PacketLogger；语音需安装 /Applications/PacketLogger.app，按键接管可独立使用"
        case -1003: "PacketLogger 未通过 Apple 签名校验；请使用 Apple 官方工具，按键接管可独立使用"
        case -1004: "PacketLogger 命令行工具不可执行；请重新安装 Apple 官方工具"
        case -1002, 0: "临时接管进程未建立通信，请重新启动按键接管（\(code)）"
        case errAuthorizationCanceled: "已取消系统认证，目标按键接管尚未启动"
        case errAuthorizationDenied: "系统未允许临时管理员接管（\(code)）"
        default: "临时接管启动失败（\(code)）"
        }
    }
}

/// Wire messages contain only target reports; raw HCI lines never leave the helper.
enum CaptureMessage {
    case ready, audioReset, audioMode(Bool), isolation(Bool), keyboard([UInt8]), voice([UInt8], UInt16), status(String), failure(String)
    static func parse(_ line: String) -> CaptureMessage? {
        if line.hasPrefix("ERROR "), line.count < 1024 { return .failure(String(line.dropFirst(6))) }
        if line == "A 0" { return .audioReset }
        if line == "M 1" { return .audioMode(true) }
        if line == "M 0" { return .audioMode(false) }
        if line == "READY" { return .ready }
        if line == "I 1" { return .isolation(true) }
        if line == "I 0" { return .isolation(false) }
        if line.hasPrefix("S "), line.count < 1024 { return .status(String(line.dropFirst(2))) }
        if line.hasPrefix("K ") {
            let text = Array(line.dropFirst(2))
            guard text.count == 18 else { return nil }
            var report: [UInt8] = []
            for i in stride(from: 0, to: text.count, by: 2) {
                guard let byte = UInt8(String(text[i...i+1]), radix: 16) else { return nil }
                report.append(byte)
            }
            guard report.first == 1 else { return nil }
            return .keyboard(report)
        }
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "F", let handle = UInt16(parts[1]), handle <= 0xFFF,
              let data = Data(base64Encoded: String(parts[2])),
              ClassicVoiceFrame.parse(Array(data), reportID: 0xF7) != nil else { return nil }
        return .voice(Array(data), handle)
    }
}

@MainActor
final class HCIVoiceInput {
    private static let logger = Logger(subsystem: "local.iprc1000.adapter", category: "CaptureConnection")
    var onKeyboard: ([UInt8]) -> Void = { _ in }
    var onIsolation: (Bool) -> Void = { _ in }
    var onReport: ([UInt8], Bool) -> Void = { _, _ in }
    var onStatus: (String, Bool) -> Void = { _, _ in }
    var onAudioAvailable: (Bool) -> Void = { _ in }
    var onInputDiagnostics: (String) -> Void = { _ in }
    var onAudioMode: (Bool) -> Void = { _ in }
    private(set) var audioEnabled = false
    private var wantsAudio = false
    private var wantsScopedAudio = false
    private(set) var isRunning = false
    private var generation = 0
    private var descriptor: Int32 = -1
    private var timer: Timer?
    private var pending = Data()
    private var isolated = false
    private var handle: UInt16?
    private var frames = 0
    private var keyboardReports = 0

    func start(audio: Bool = true) {
        guard !isRunning else {
            if audio { startAudio() }
            return
        }
        let targets = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? [])
            .filter { $0.name == TargetRemote.productName }
        guard targets.count == 1, let address = targets.first?.addressString,
              TargetRemote.normalizedAddress(address).count == 12, let executable = Bundle.main.executablePath else {
            onStatus("需要唯一已配对的 IPRC1000", false); return
        }
        let targetAddress = TargetRemote.normalizedAddress(address)
        generation += 1
        let session = generation
        isRunning = true
        wantsAudio = audio
        onStatus("等待管理员认证：仅接管目标遥控器按键，不依赖 PacketLogger", false)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var fd: Int32 = -1
            let result = iprc_hci_open(executable, targetAddress, &fd)
            let opened = fd
            DispatchQueue.main.async {
                guard let self, self.generation == session else {
                    if opened >= 0 { close(opened) }; return
                }
                guard result == 0, opened >= 0 else {
                    self.stop()
                    self.onStatus(CaptureFailure.message(result), false); return
                }
                self.descriptor = opened
                _ = fcntl(opened, F_SETFL, fcntl(opened, F_GETFL) | O_NONBLOCK)
                _ = fcntl(opened, F_SETNOSIGPIPE, 1)
                self.timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.readAvailable() }
                }
            }
        }
    }

    func stop() {
        if descriptor >= 0 { Self.logger.notice("foreground closing temporary capture connection") }
        generation += 1
        timer?.invalidate(); timer = nil
        if descriptor >= 0 { close(descriptor); descriptor = -1 }
        pending.removeAll()
        wantsAudio = false
        wantsScopedAudio = false
        audioEnabled = false
        onAudioMode(false)
        isolated = false; handle = nil; frames = 0; keyboardReports = 0; isRunning = false
        publishDiagnostics()
        onIsolation(false); onAudioAvailable(false)
        onStatus("临时捕获已停止，目标按键接管已释放", false)
    }

    func retryAudio() {
        guard audioEnabled else { return }
        guard send(.retryAudio) else {
            onStatus("音频重试请求未发送，捕获连接可能已结束", isRunning)
            return
        }
        onStatus("正在重试音频接收；目标按键接管保持", true)
    }

    func startAudio() {
        wantsAudio = true
        wantsScopedAudio = false
        guard descriptor >= 0 else { return }
        if !send(.startAudio) { onStatus("音频启动请求未发送，请检查按键接管连接", true) }
    }

    func startScopedAudio() {
        if !isRunning { start(audio: false) }
        guard isRunning else { return }
        wantsAudio = false
        wantsScopedAudio = true
        if descriptor >= 0 { _ = send(.startScopedAudio); wantsScopedAudio = false }
    }

    func stopAudio() {
        wantsAudio = false
        wantsScopedAudio = false
        if descriptor >= 0 { _ = send(.stopAudio) }
        audioEnabled = false
        onAudioMode(false)
        onAudioAvailable(false)
    }

    private func send(_ command: CaptureCommand) -> Bool {
        guard descriptor >= 0, fcntl(descriptor, F_GETNOSIGPIPE, 0) == 1 else { return false }
        var byte = command.rawValue
        return Darwin.write(descriptor, &byte, 1) == 1
    }

    private func readAvailable() {
        var bytes = [UInt8](repeating: 0, count: 65536)
        let count = read(descriptor, &bytes, bytes.count)
        if count < 0 {
            if errno != EAGAIN && errno != EINTR {
                Self.logger.error("capture read failed errno=\(errno)")
                stop()
            }
            return
        }
        guard count > 0 else {
            Self.logger.notice("capture helper reached EOF")
            stop(); return
        }
        pending.append(contentsOf: bytes.prefix(count))
        while let end = pending.firstIndex(of: 10) {
            let line = String(decoding: pending[..<end], as: UTF8.self)
            pending.removeSubrange(...end)
            guard let message = CaptureMessage.parse(line) else { continue }
            switch message {
            case .audioMode(let enabled):
                audioEnabled = enabled
                onAudioMode(enabled)
                if !enabled { handle = nil; onAudioAvailable(false) }
                publishDiagnostics()
            case .audioReset:
                handle = nil
                onAudioAvailable(false)
                if isolated { onIsolation(false); onIsolation(true) }
            case .ready:
                onStatus("目标按键接管进程已启动；音频可单独开启", true)
                if wantsScopedAudio { _ = send(.startScopedAudio); wantsScopedAudio = false }
                else if wantsAudio { startAudio() }
            case .isolation(let ready):
                isolated = ready; handle = nil
                onIsolation(ready)
                if !ready { onAudioAvailable(false) }
                publishDiagnostics()
            case .keyboard(let report):
                if isolated {
                    keyboardReports += 1
                    onKeyboard(report)
                    publishDiagnostics()
                }
            case .voice(let report, let nextHandle):
                guard isolated, audioEnabled else { continue }
                let changed = handle != nextHandle
                handle = nextHandle
                frames += 1
                onAudioAvailable(true)
                onReport(report, changed)
                if frames == 1 || frames % 50 == 0 {
                    onStatus("目标 HCI F7：\(frames) 帧", true)
                    publishDiagnostics()
                }
            case .status(let status):
                onStatus(status, true)
                publishDiagnostics()
            case .failure(let error):
                stop(); onStatus(error, false); return
            }
        }
        if pending.count > 65536 { stop() }
    }

    private func publishDiagnostics() {
        onInputDiagnostics("目标独占：\(isolated ? "已接管" : "等待连接") · 按键报告 \(keyboardReports) · 音频\(audioEnabled ? "已启用" : "已关闭") · HCI F7 \(frames) 帧")
    }
}

/// Drop an oversized unrelated HCI line, not the target keyboard session.
struct BoundedCaptureLines {
    private var pending = Data()
    private var discarding = false
    mutating func append(_ data: Data) -> [String] {
        var lines: [String] = []
        for byte in data {
            if byte == 10 {
                if !discarding { lines.append(String(decoding: pending, as: UTF8.self)) }
                pending.removeAll(keepingCapacity: true)
                discarding = false
            } else if !discarding {
                if pending.count == 65536 {
                    pending.removeAll(keepingCapacity: true)
                    discarding = true
                } else { pending.append(byte) }
            }
        }
        return lines
    }
}

/// A restarted decoder can include buffered packets. Never replay audio that
/// was already forwarded, including when the connection handle has changed.
struct HCIFrameWatermark {
    private var latest: Date?
    private var identities = Set<UInt32>()
    private let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let whole = ISO8601DateFormatter()
    var canResumeBuffered: Bool { latest != nil }

    mutating func accept(timestamp: String, handle: UInt16, report: [UInt8]) -> Bool {
        guard report.count == 652, report.first == 0xF7,
              let time = fractional.date(from: timestamp) ?? whole.date(from: timestamp) else { return false }
        let sequence = UInt16(report[2]) | UInt16(report[3]) << 8
        let identity = UInt32(handle) << 16 | UInt32(sequence)
        if let latest {
            if time < latest { return false }
            if time == latest { return identities.insert(identity).inserted }
        }
        latest = time
        identities = [identity]
        return true
    }
}
