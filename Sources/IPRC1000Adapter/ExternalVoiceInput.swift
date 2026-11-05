import CoreAudio
import Carbon
import Foundation
import AppKit
import os

enum VoiceInputProvider: String, CaseIterable, Identifiable {
    case systemSpeech
    case externalIME
    var id: String { rawValue }
    var title: String {
        self == .systemSpeech ? "macOS 本机识别 → 光标输入" : "外部语音输入法（微信等）"
    }
}

/// The external IME owns recognition and insertion. Only its microphone source and shortcut are routed here.
@MainActor
final class ExternalVoiceInput {
    nonisolated private static let logger = Logger(subsystem: "local.iprc1000.adapter", category: "WeChatStream")
    var onStatus: (String) -> Void = { _ in }
    var onBeforeFn: () -> Bool = { true }
    private var previousInput: AudioDeviceID?
    private var blackHole: AudioDeviceID?
    private var heldShortcut: KeyBinding?
    private var generation = 0
    private var finishing = false
    private var toggleShortcut = false
    private var shortcutSent = false
    private var previousSource: String?
    private static let weTypePrefix = "com.tencent.inputmethod.wetype"
    private var helper: Process?
    private var helperWriter: PCMStreamWriter?
    private var helperOwnsAudioOnly = false
    private var helperOutput = ""
    private var helperFirstAudioLogged = false
    private var helperFnHeld = false
    private var helperCancelled = false
    private var warmup = VoiceWarmup()
    private var helperStartupTimeout: DispatchWorkItem?
    private var helperDrainTimeout: DispatchWorkItem?
    private var pendingShortcut: (KeyBinding, Bool)?
    private var pendingSamples: [Int16] = []
    private var pendingFinished = false
    private var pressGeneration = 0
    private var receivedSamplesInPress = false
    var usingHelper: Bool { helper != nil || pendingShortcut != nil }
    var active: Bool { heldShortcut != nil || usingHelper }

    func begin(shortcut: KeyBinding, toggle: Bool) -> String {
        guard onBeforeFn() else {
            stop()
            return "遥控器输入通道未就绪，未启动外部语音"
        }
        pressGeneration += 1
        receivedSamplesInPress = false
        if helper != nil || pendingShortcut != nil {
            if finishing || helper == nil {
                pendingShortcut = (shortcut, toggle)
                pendingFinished = false
                return "已接收下一次按键，保留音频并等待上一句排空"
            }
            return "微信语音继续输入中"
        }
        if shortcut.isFunctionOnly && !toggle { return startWeChatHelper() }
        if heldShortcut != nil {
            if finishing { generation += 1; finishing = false }
            return "外部语音继续输入中"
        }
        guard shortcut.kind == .keyboard else { return "请配置外部输入法的语音快捷键" }
        if shortcut.isFunctionOnly, !selectWeType() {
            return "无法选中微信输入源；请先在系统中启用微信输入法"
        }
        guard let device = BlackHoleOutput.findDevice(named: "BlackHole 2ch"),
              let current = defaultInput(), setDefaultInput(device) else {
            restoreInput()
            return "无法将外部输入法麦克风切换到 BlackHole 2ch"
        }
        if previousInput == nil { previousInput = current }
        blackHole = device
        generation += 1
        toggleShortcut = toggle
        heldShortcut = shortcut
        let session = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.generation == session, self.heldShortcut != nil else { return }
            if shortcut.isFunctionOnly,
               Self.sourceID(TISCopyCurrentKeyboardInputSource().takeRetainedValue())?.hasPrefix(Self.weTypePrefix) != true {
                self.stop()
                self.onStatus("微信输入源未成功选中，已恢复默认麦克风")
                return
            }
            guard self.onBeforeFn() else {
                self.stop()
                self.onStatus("遥控器输入通道已失效，已恢复现场")
                return
            }
            KeyEmitter.emit(shortcut)
            self.shortcutSent = true
        }
        return "流式输入中：BlackHole 2ch → 微信语音；结束后恢复默认麦克风"
    }

    func finish() {
        if pendingShortcut != nil { pendingFinished = true; return }
        if helper != nil {
            guard !finishing, let writer = helperWriter else { return }
            finishing = true
            watchHelperDrain()
            if helperOwnsAudioOnly && !warmup.finish() { return }
            writer.finish()
            return
        }
        guard heldShortcut != nil else { return }
        guard !finishing else { return }
        finishing = true
        let session = generation
        // Allow the already queued final audio to reach the IME before releasing its shortcut.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.generation == session, let shortcut = self.heldShortcut else { return }
            if self.shortcutSent {
                KeyEmitter.release(shortcut)
                if self.toggleShortcut && !shortcut.requiresReleaseEvent { KeyEmitter.emit(shortcut) }
            }
            self.heldShortcut = nil
            self.finishing = false
            self.shortcutSent = false
            self.restoreInput()
        }
    }

    func remoteReleased() {
        guard helper != nil else { return }
        let press = pressGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.pressGeneration == press, !self.receivedSamplesInPress else { return }
            self.finish()
        }
    }

    func stop() {
        pendingShortcut = nil
        pendingSamples.removeAll()
        pendingFinished = false
        helperCancelled = true
        helperStartupTimeout?.cancel(); helperStartupTimeout = nil
        helperDrainTimeout?.cancel(); helperDrainTimeout = nil
        if helper != nil {
            finishing = true
            helperWriter?.cancel()
            warmup = VoiceWarmup()
            if helperFnHeld { KeyEmitter.release(.modifierOnly([.function])) }
            helperFnHeld = false
            if helperOwnsAudioOnly { restoreInput() }
            if helper?.isRunning == true { helper?.terminate() }
            return
        }
        generation += 1
        finishing = false
        if let heldShortcut, shortcutSent {
            KeyEmitter.release(heldShortcut)
            if toggleShortcut && !heldShortcut.requiresReleaseEvent { KeyEmitter.emit(heldShortcut) }
        }
        heldShortcut = nil
        shortcutSent = false
        restoreInput()
    }

    func append(_ samples: [Int16]) {
        if !samples.isEmpty { receivedSamplesInPress = true }
        if pendingShortcut != nil {
            guard samples.count <= VoiceWarmup.capacity - pendingSamples.count else {
                stop(); onStatus("下一句等待过久，已停止语音并恢复麦克风"); return
            }
            pendingSamples.append(contentsOf: samples); return
        }
        guard !finishing, helperWriter != nil, !samples.isEmpty else { return }
        if helperOwnsAudioOnly {
            do {
                if let ready = try warmup.append(samples) { writePCM(ready) }
            } catch {
                stop(); onStatus("微信启动等待过久，已停止语音并恢复麦克风")
            }
        } else { writePCM(samples) }
    }

    private func writePCM(_ samples: [Int16]) {
        guard let writer = helperWriter, !samples.isEmpty else { return }
        var littleEndian = samples.map { $0.littleEndian }
        let data = littleEndian.withUnsafeMutableBytes { Data($0) }
        if !writer.append(data) {
            stop()
            onStatus("微信音频发送积压，已停止语音并恢复麦克风")
        }
    }

    private func watchHelperDrain() {
        guard let process = helper else { return }
        helperDrainTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self, weak process] in
            guard let self, let process, self.helper === process, self.finishing,
                  !self.helperCancelled else { return }
            self.stop()
            self.onStatus("微信音频结束超时，已释放快捷键并恢复麦克风")
        }
        helperDrainTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
    }

    private func startWeChatHelper() -> String {
        let installed = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VibeStick/vibe_stick_wechat_input.app/Contents/MacOS/vibe_stick_wechat_input")
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("WeChatInputHelper.app/Contents/MacOS/vibe_stick_wechat_input")
        guard let executable = [bundled, installed].compactMap({ $0 }).first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            return "缺少微信流式组件，请重新安装应用"
        }
        let audioOnly = executable == bundled
        if audioOnly {
            guard selectWeType(), let device = BlackHoleOutput.findDevice(named: "BlackHole 2ch"),
                  let current = defaultInput(), setDefaultInput(device) else {
                restoreInput()
                return "无法准备微信输入源或 BlackHole 麦克风"
            }
            if previousInput == nil { previousInput = current }
            blackHole = device
        }
        let process = Process()
        let input = Pipe()
        let errors = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = audioOnly ? ["--stream", "--audio-only"] : ["--stream"]
        process.standardInput = input
        process.standardOutput = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async {
                guard let self, self.helper === process else { return }
                self.helperOutput += text
                if !self.helperFirstAudioLogged, self.helperOutput.contains("IPRC_AUDIO_FIRST_BUFFER") {
                    self.helperFirstAudioLogged = true
                    Self.logger.notice("helper scheduled first PCM buffer")
                }
                if self.helperOwnsAudioOnly, !self.helperCancelled,
                   self.helperOutput.contains("IPRC_AUDIO_READY"), self.warmup.helperReady() {
                    guard self.onBeforeFn() else {
                        self.stop()
                        self.onStatus("无法在微信之前拦截遥控器按键，已停止语音并恢复现场")
                        return
                    }
                    let delay = self.helperFnHeld ? 0.0 : 0.35
                    if !self.helperFnHeld {
                        KeyEmitter.emit(.modifierOnly([.function]))
                        self.helperFnHeld = true
                    }
                    Self.logger.notice("helper ready; Fn held; retaining PCM during IME warmup")
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        guard self.helper === process, !self.helperCancelled,
                              let buffered = self.warmup.release() else { return }
                        self.helperStartupTimeout?.cancel(); self.helperStartupTimeout = nil
                        self.writePCM(buffered.samples)
                        Self.logger.notice("IME warmup complete; prefix samples=\(buffered.samples.count, privacy: .public) finish=\(buffered.finish, privacy: .public)")
                        if buffered.finish { self.helperWriter?.finish() }
                        self.onStatus("Fn 已按下，正在流式输入微信语音")
                    }
                }
            }
        }
        process.standardError = errors
        process.terminationHandler = { [weak self] child in
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let code = child.terminationStatus
            Self.logger.notice("helper exit pid=\(child.processIdentifier) code=\(code) detail=\(message, privacy: .public)")
            DispatchQueue.main.async {
                guard let self, self.helper === child else { return }
                self.helperStartupTimeout?.cancel(); self.helperStartupTimeout = nil
                self.helperDrainTimeout?.cancel(); self.helperDrainTimeout = nil
                output.fileHandleForReading.readabilityHandler = nil
                let continuing = self.pendingShortcut != nil && code == 0
                if self.helperFnHeld && !continuing {
                    KeyEmitter.release(.modifierOnly([.function]))
                    self.helperFnHeld = false
                }
                if self.helperOwnsAudioOnly && self.pendingShortcut == nil { self.restoreInput() }
                self.helper = nil
                self.helperWriter?.cancel(); self.helperWriter = nil
                self.finishing = false
                if !self.helperCancelled {
                    self.onStatus(code == 0 ? (self.pendingShortcut == nil ? "微信流式会话结束，已恢复默认麦克风" : "上一段已结束，保留音频并接续下一段") : "微信语音启动失败：\(message.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
                if self.pendingShortcut != nil {
                    if let pending = self.pendingShortcut {
                        let samples = self.pendingSamples
                        let ended = self.pendingFinished
                        self.pendingShortcut = nil
                        self.pendingSamples.removeAll()
                        self.pendingFinished = false
                        self.onStatus(self.begin(shortcut: pending.0, toggle: pending.1))
                        guard self.helper != nil else {
                            if self.helperFnHeld { KeyEmitter.release(.modifierOnly([.function])) }
                            self.helperFnHeld = false
                            self.restoreInput()
                            return
                        }
                        self.append(samples)
                        if ended { self.finish() }
                    }
                }
            }
        }
        signal(SIGPIPE, SIG_IGN)
        helperOutput = ""
        helperFirstAudioLogged = false
        warmup = VoiceWarmup()
        helperCancelled = false
        helperOwnsAudioOnly = audioOnly
        let writer: PCMStreamWriter
        do {
            writer = try PCMStreamWriter(input.fileHandleForWriting) { [weak self, weak process] message in
                Self.logger.error("\(message, privacy: .public)")
                DispatchQueue.main.async {
                    guard let self, let process, self.helper === process, !self.helperCancelled else { return }
                    self.stop()
                    self.onStatus("微信音频管道中断，已释放快捷键并恢复麦克风")
                }
            }
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            restoreInput()
            return "无法启动微信流式组件：\(error.localizedDescription)"
        }
        helper = process
        let foreground = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
        Self.logger.notice("helper launched pid=\(process.processIdentifier) executable=\(executable.path, privacy: .public) foreground=\(foreground, privacy: .public)")
        helperWriter = writer
        finishing = false
        if audioOnly {
            let timeout = DispatchWorkItem { [weak self, weak process] in
                guard let self, let process, self.helper === process,
                      !self.helperCancelled, !self.warmup.isStreaming else { return }
                self.stop()
                self.onStatus("微信音频组件未及时就绪，已停止语音并恢复麦克风")
            }
            helperStartupTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
        }
        return "微信流式会话已启动，遥控器音频将实时送入微信"
    }

    private func restoreInput() {
        if let previousInput, defaultInput() == blackHole { _ = setDefaultInput(previousInput) }
        previousInput = nil
        blackHole = nil
        if let previousSource, Self.sourceID(TISCopyCurrentKeyboardInputSource().takeRetainedValue())?.hasPrefix(Self.weTypePrefix) == true {
            if let source = Self.sources().first(where: { Self.sourceID($0) == previousSource }) {
                _ = TISSelectInputSource(source)
            }
        }
        previousSource = nil
    }

    private static func sourceID(_ source: TISInputSource) -> String? {
        guard let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
    }

    private static func sources() -> [TISInputSource] {
        (TISCreateInputSourceList(nil, false).takeRetainedValue() as NSArray).map { $0 as! TISInputSource }
    }

    private func selectWeType() -> Bool {
        let current = Self.sourceID(TISCopyCurrentKeyboardInputSource().takeRetainedValue())
        if current?.hasPrefix(Self.weTypePrefix) == true { return true }
        guard let source = Self.sources().first(where: {
            guard Self.sourceID($0)?.hasPrefix(Self.weTypePrefix) == true,
                  let enabled = TISGetInputSourceProperty($0, kTISPropertyInputSourceIsEnabled),
                  let selectable = TISGetInputSourceProperty($0, kTISPropertyInputSourceIsSelectCapable) else { return false }
            return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(enabled).takeUnretainedValue())
                && CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(selectable).takeUnretainedValue())
        }),
              TISSelectInputSource(source) == noErr else { return false }
        if previousSource == nil { previousSource = current }
        return true
    }

    private func defaultInput() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
            0, nil, &size, &device) == noErr else { return nil }
        return device
    }

    private func setDefaultInput(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value = device
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
            0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &value) == noErr
    }
}
