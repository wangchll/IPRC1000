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
    @Published var lastKey = "—"
    @Published var lastRemoteKey: RemoteKey?

    private let hid = HIDController()
    private let voice = VoiceController()
    private var started = false
    private var hidStarted = false
    private var heldBindings: [RemoteKey: KeyBinding] = [:]

    func start() {
        guard !started else { return }
        started = true

        hid.onStatus = { [weak self] message, ready in
            Task { @MainActor in
                self?.hidStatus = message
                self?.hidReady = ready
            }
        }
        hid.onKey = { [weak self] key in
            Task { @MainActor in
                guard let self else { return }
                self.lastKey = key.title
                self.lastRemoteKey = key
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
            Task { @MainActor in
                guard let self else { return }
                guard key != .unknown16 else { return }
                KeyEmitter.emitRepeat(self.mappings.values[key] ?? .none)
            }
        }
        hid.onKeyUp = { [weak self] key in
            Task { @MainActor in
                guard let self else { return }
                guard key != .unknown16 else { return }
                let binding = self.heldBindings.removeValue(forKey: key)
                    ?? self.mappings.values[key] ?? .none
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

        preparePermissions()
        voice.start()
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
