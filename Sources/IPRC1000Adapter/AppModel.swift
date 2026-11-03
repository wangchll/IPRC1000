import AppKit
import ApplicationServices
import Foundation
import IOKit.hid

@MainActor
final class AppModel: ObservableObject {
    let mappings = MappingStore()

    @Published var hidStatus = "正在启动按键适配…"
    @Published var hidReady = false
    @Published var voiceStatus = "正在启动语音适配…"
    @Published var voiceReady = false
    @Published var voiceLevel: Float = 0
    @Published var voiceInputDiagnostics = "尚未收到设备报告"
    @Published var deviceVoiceStatus = "临时 HCI 音频未启动；按键仅接管目标遥控器"
    @Published var deviceVoiceActive = false
    @Published var deviceAudioAvailable = false
    @Published var deviceAudioEnabled = false
    @Published var transcript = ""
    @Published var transcriptionStatus = "转写未启动"
    @Published var cursorInputStatus = "启用后，请点入目标输入框，按住遥控器麦克风说话，松开后自动输入"
    @Published var inputEnabled = false
    @Published var inputRequested = false
    @Published var inputProvider = VoiceInputProvider(rawValue: UserDefaults.standard.string(forKey: "voiceInputProvider") ?? "") ?? .systemSpeech {
        didSet {
            stopVoiceInput()
            UserDefaults.standard.set(inputProvider.rawValue, forKey: "voiceInputProvider")
        }
    }
    @Published var externalShortcut: KeyBinding = {
        guard let data = UserDefaults.standard.data(forKey: "externalVoiceShortcut"),
              let binding = try? JSONDecoder().decode(KeyBinding.self, from: data) else {
            return .modifierOnly([.function])
        }
        return binding
    }() {
        didSet {
            stopVoiceInput()
            if let data = try? JSONEncoder().encode(externalShortcut) {
                UserDefaults.standard.set(data, forKey: "externalVoiceShortcut")
            }
        }
    }
    @Published var externalShortcutToggles = UserDefaults.standard.bool(forKey: "externalVoiceShortcutToggles") {
        didSet {
            stopVoiceInput()
            UserDefaults.standard.set(externalShortcutToggles, forKey: "externalVoiceShortcutToggles")
        }
    }
    @Published var lastKey = "—"
    @Published var lastRemoteKey: RemoteKey?

    private let hid = HIDController()
    private let voice = VoiceController()
    private let deviceVoice = HCIVoiceInput()
    private let transcription = VoiceTranscription()
    private let cursorInput = CursorTextInput()
    private let externalVoice = ExternalVoiceInput()
    private var voiceFilterTimer: Timer?
    private var started = false
    private var hidStarted = false
    private var heldBindings: [RemoteKey: KeyBinding] = [:]

    func start() {
        guard !started else { return }
        started = true

        hid.onStatus = { [weak self] message, ready in
            MainActor.assumeIsolated {
                guard let self else { return }
                let lostMapping = self.hidReady && !ready
                self.hidStatus = message
                self.hidReady = ready
                if lostMapping && self.inputEnabled {
                    self.stopVoiceInput(preservingRequest: true)
                    self.cursorInputStatus = "遥控器按键通道已失效，已停止语音并恢复现场"
                }
            }
        }
        hid.onKey = { [weak self] key in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.lastKey = key.title
                self.lastRemoteKey = key
                if key == .microphone, self.inputEnabled {
                    if self.inputProvider == .externalIME {
                        let wasActive = self.externalVoice.active
                        self.cursorInputStatus = self.externalVoice.begin(shortcut: self.externalShortcut, toggle: self.externalShortcutToggles)
                        if !wasActive && self.externalVoice.active {
                            if self.externalVoice.usingHelper { self.voice.directBlackHoleOutput = false }
                            else { self.voice.prepareExternalAudio() }
                        }
                    }
                    return
                }
                if key == .unknown16 {
                    if let profileName = self.mappings.selectNextProfile() {
                        self.lastKey = "已切换：\(profileName)"
                    }
                    return
                }
                let binding = self.mappings.values[key] ?? .none
                if binding.requiresReleaseEvent { self.heldBindings[key] = binding }
                KeyEmitter.emit(binding)
            }
        }
        hid.onKeyRepeat = { [weak self] key in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard key != .unknown16 else { return }
                if key == .microphone, self.inputEnabled { return }
                KeyEmitter.emitRepeat(self.mappings.values[key] ?? .none)
            }
        }
        hid.onKeyUp = { [weak self] key in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard key != .unknown16 else { return }
                if let held = self.heldBindings.removeValue(forKey: key) {
                    KeyEmitter.release(held)
                    return
                }
                if key == .microphone, self.inputEnabled {
                    // Finish external input only after the actual PCM queue has drained.
                    if self.inputProvider == .externalIME { self.externalVoice.remoteReleased() }
                    return
                }
                let binding = self.mappings.values[key] ?? .none
                KeyEmitter.release(binding)
            }
        }
        voice.onStatus = { [weak self] message, ready in
            Task { @MainActor in
                self?.voiceStatus = message
                self?.voiceReady = ready
            }
        }
        voice.onLevel = { [weak self] level in
            Task { @MainActor in self?.voiceLevel = level }
        }

        hid.onInputDiagnostics = { [weak self] message in
            MainActor.assumeIsolated { self?.voiceInputDiagnostics = message }
        }
        hid.onVoiceReport = { [weak self] report, reportID in
            // IOHID is scheduled on the main runloop; preserve report/lifecycle ordering.
            MainActor.assumeIsolated {
                guard let self, !self.deviceVoiceActive else { return }
                self.voice.receive(report, reportID: reportID)
            }
        }
        hid.onVoiceConnection = { [weak self] ready in
            MainActor.assumeIsolated {
                guard let self, !self.deviceVoiceActive else { return }
                self.voice.connectionChanged(ready)
            }
        }
        deviceVoice.onIsolation = { [weak self] ready in
            guard let self else { return }
            self.hid.exclusiveConnectionChanged(ready)
            if ready && self.inputRequested { self.enableTranscription() }
            if !ready {
                self.stopVoiceInput(preservingRequest: true)
                if self.inputRequested { self.cursorInputStatus = "已启用，等待目标遥控器重新连接" }
            }
        }
        deviceVoice.onKeyboard = { [weak self] report in
            self?.hid.receiveExclusiveKeyboard(report)
        }
        deviceVoice.onInputDiagnostics = { [weak self] message in
            self?.voiceInputDiagnostics = message
        }
        deviceVoice.onStatus = { [weak self] message, active in
            let wasActive = self?.deviceVoiceActive == true
            self?.deviceVoiceStatus = message
            self?.deviceVoiceActive = active
            if !active { self?.voice.connectionChanged(false) }
            if wasActive && !active { self?.stopVoiceInput() }
        }
        deviceVoice.onAudioAvailable = { [weak self] available in
            guard let self else { return }
            self.deviceAudioAvailable = available
            if !available {
                self.voice.connectionChanged(false)
            }
        }
        deviceVoice.onAudioMode = { [weak self] enabled in
            guard let self else { return }
            self.deviceAudioEnabled = enabled
            if !enabled {
                self.stopVoiceInput(preservingRequest: true)
                self.voice.connectionChanged(false)
            } else if self.inputRequested { self.enableTranscription() }
        }
        deviceVoice.onReport = { [weak self] report, changed in
            guard let self else { return }
            if changed { self.voice.connectionChanged(true) }
            self.voice.receive(report, reportID: 0xF7)
        }
        externalVoice.onBeforeFn = { [weak self] in self?.hid.prepareDeviceFilter() == true }
        externalVoice.onStatus = { [weak self] message in self?.cursorInputStatus = message }
        transcription.onText = { [weak self] text in self?.transcript = text }
        transcription.onStatus = { [weak self] text in self?.transcriptionStatus = text }
        transcription.onEnabled = { [weak self] enabled in self?.inputEnabled = enabled }
        transcription.onBegin = { [weak self] in
            let target = CursorTextInput()
            target.onStatus = { [weak self] message in self?.cursorInputStatus = message }
            target.begin()
            return { [weak self] text in
                self?.cursorInputStatus = target.insert(text)
            }
        }
        cursorInput.onStatus = { [weak self] message in self?.cursorInputStatus = message }
        voice.onSamples = { [weak self] samples in
            MainActor.assumeIsolated {
                guard let self, self.inputEnabled else { return }
                if self.inputProvider == .systemSpeech { self.transcription.append(samples) }
                else if self.externalVoice.usingHelper { self.externalVoice.append(samples) }
            }
        }
        voice.onUtteranceEnd = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.inputProvider == .systemSpeech { self.transcription.finish() }
                else { self.externalVoice.finish() }
            }
        }
        voice.start()
        preparePermissions()
    }

    func shutdown() {
        deviceVoice.stop()
        stopVoiceInput()
        hid.stop()
        for binding in heldBindings.values { KeyEmitter.release(binding) }
        heldBindings.removeAll()
    }

    func startDeviceVoice() {
        if !deviceVoice.isRunning { hid.stop() }
        deviceVoice.start(audio: true)
    }
    func startKeyboardAdaptation() {
        if !deviceVoice.isRunning { hid.stop() }
        deviceVoice.start(audio: false)
    }
    func stopDeviceAudio() {
        stopVoiceInput()
        deviceVoice.stopAudio()
    }
    func retryDeviceAudio() { deviceVoice.retryAudio() }
    func stopDeviceVoice() {
        deviceVoice.stop()
        stopVoiceInput()
        if hidStarted { hid.start() }
    }
    func enableTranscription() {
        guard deviceVoiceActive, deviceAudioEnabled else {
            cursorInputStatus = "请先启动临时蓝牙语音捕获"
            return
        }
        inputRequested = true
        guard hid.prepareDeviceFilter() else {
            cursorInputStatus = "已启用，等待目标遥控器独占接管后开始输入"
            return
        }
        guard !inputEnabled else { return }
        if inputProvider == .systemSpeech { transcription.enable() }
        else {
            guard externalShortcut.kind == .keyboard else {
                cursorInputStatus = "请配置外部输入法的语音快捷键"
                return
            }
            inputEnabled = true
            guard hid.maintainDeviceFilter() else {
                inputEnabled = false
                cursorInputStatus = "遥控器设备定向屏蔽未就绪，语音输入未启用"
                return
            }
            voiceFilterTimer?.invalidate()
            voiceFilterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if !self.hid.maintainDeviceFilter() {
                        self.stopVoiceInput(preservingRequest: true)
                        self.cursorInputStatus = "设备定向屏蔽失效，已停用语音并恢复现场"
                    }
                }
            }
            transcriptionStatus = "由外部输入法完成识别与光标输入"
            cursorInputStatus = "已启用；按住遥控器说话时临时使用 BlackHole，结束后恢复系统麦克风"
        }
    }

    func stopVoiceInput(preservingRequest: Bool = false) {
        if !preservingRequest { inputRequested = false }
        voiceFilterTimer?.invalidate()
        voiceFilterTimer = nil
        inputEnabled = false
        transcription.disable()
        externalVoice.stop()
        voice.cancelExternalAudio()
        voice.directBlackHoleOutput = true
        cursorInputStatus = "语音输入已停用"
    }

    func testCursorInput() {
        guard let page = Bundle.main.url(forResource: "VoiceInputTest", withExtension: "html") else {
            cursorInputStatus = "缺少输入测试页"
            return
        }
        let browser = URL(fileURLWithPath: "/Applications/Microsoft Edge.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        cursorInputStatus = "正在打开独立浏览器测试页…"
        NSWorkspace.shared.open([page], withApplicationAt: browser, configuration: configuration) { [weak self] browserApp, error in
            let message = error?.localizedDescription
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard let self else { return }
                if let message { self.cursorInputStatus = "无法打开测试页：\(message)"; return }
                browserApp?.activate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == browserApp?.processIdentifier else {
                        self.cursorInputStatus = "浏览器未处于前台，请点击测试输入框"
                        return
                    }
                    self.cursorInput.begin()
                    self.cursorInputStatus = self.cursorInput.insert("光标输入测试成功")
                }
            }
        }
    }

    /// Automatic startup never re-prompts a permission that was already answered.
    private func preparePermissions() {
        let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        switch access {
        case kIOHIDAccessTypeGranted:
            startHID()
        case kIOHIDAccessTypeUnknown:
            let key = "inputMonitoringPromptRequested"
            guard !UserDefaults.standard.bool(forKey: key) else {
                hidStatus = "等待输入监控授权；不会重复弹窗"
                return
            }
            UserDefaults.standard.set(true, forKey: key)
            if IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) {
                startHID()
            } else {
                hidStatus = "输入监控未授权；请从状态栏打开隐私设置"
            }
        default:
            hidStatus = "输入监控未授权；请从状态栏打开隐私设置"
        }
    }

    private func startHID() {
        guard !hidStarted else { return }
        hidStarted = true
        hid.start()
    }

    /// User-initiated permission action. This is the only path allowed to show a prompt again.
    func requestPermissions() {
        if !AXIsProcessTrusted() {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted:
            startHID()
        case kIOHIDAccessTypeUnknown:
            UserDefaults.standard.set(true, forKey: "inputMonitoringPromptRequested")
            if IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) { startHID() }
        default:
            openPrivacySettings()
        }
    }

    private func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else { return }
        NSWorkspace.shared.open(url)
    }
}
