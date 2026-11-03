import ApplicationServices
import AudioToolbox
import AVFoundation
import Carbon
import Foundation

enum HelperError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let value): value
        }
    }
}

func currentInputSourceIdentifier() throws -> String {
    let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    guard let rawIdentifier = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
        throw HelperError.message("Could not read the current macOS input source")
    }
    return Unmanaged<CFString>.fromOpaque(rawIdentifier).takeUnretainedValue() as String
}

func inputSourceIdentifier(_ source: TISInputSource) -> String? {
    guard let rawIdentifier = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
        return nil
    }
    return Unmanaged<CFString>.fromOpaque(rawIdentifier).takeUnretainedValue() as String
}

func inputSourceIsTrue(_ source: TISInputSource, _ property: CFString) -> Bool {
    guard let rawValue = TISGetInputSourceProperty(source, property) else {
        return false
    }
    return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(rawValue).takeUnretainedValue())
}

func inputSource(matching identifier: String, prefix: Bool = false) -> TISInputSource? {
    let sources = TISCreateInputSourceList(nil, false).takeRetainedValue() as NSArray
    for case let source as TISInputSource in sources {
        guard let candidate = inputSourceIdentifier(source) else { continue }
        if (prefix && candidate.hasPrefix(identifier)) || (!prefix && candidate == identifier) {
            return source
        }
    }
    return nil
}

func selectInputSource(_ identifier: String, prefix: Bool = false) throws {
    guard let source = inputSource(matching: identifier, prefix: prefix) else {
        throw HelperError.message("The required input source is not enabled: \(identifier)")
    }
    guard inputSourceIsTrue(source, kTISPropertyInputSourceIsSelectCapable),
          inputSourceIsTrue(source, kTISPropertyInputSourceIsEnabled) else {
        throw HelperError.message("The required input source is not selectable: \(identifier)")
    }
    guard TISSelectInputSource(source) == noErr else {
        throw HelperError.message("Could not select input source: \(identifier)")
    }
}

func weChatInputSourcePrefix() -> String {
    ProcessInfo.processInfo.environment["VIBE_STICK_EXTERNAL_INPUT_SOURCE_PREFIX"]
        ?? "com.tencent.inputmethod.wetype"
}

func selectWeChatInputSource() throws -> String? {
    let requiredPrefix = weChatInputSourcePrefix()
    let current = try currentInputSourceIdentifier()
    if current.hasPrefix(requiredPrefix) {
        return nil
    }
    try selectInputSource(requiredPrefix, prefix: true)
    for _ in 0..<20 {
        if try currentInputSourceIdentifier().hasPrefix(requiredPrefix) {
            return current
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
    throw HelperError.message("WeChat Input was not selected")
}

func restoreInputSource(_ identifier: String?) {
    guard let identifier else { return }
    guard let current = try? currentInputSourceIdentifier(),
          current.hasPrefix(weChatInputSourcePrefix()) else {
        return
    }
    try? selectInputSource(identifier)
}

func propertyDataSize(
    _ objectID: AudioObjectID,
    _ address: inout AudioObjectPropertyAddress
) throws -> UInt32 {
    var size: UInt32 = 0
    let status = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size)
    guard status == noErr else {
        throw HelperError.message("CoreAudio property-size lookup failed (\(status))")
    }
    return size
}

func deviceName(_ deviceID: AudioDeviceID) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var name: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    let status = withUnsafeMutablePointer(to: &name) { pointer in
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
    }
    return status == noErr ? name as String : nil
}

func hasOutputStreams(_ deviceID: AudioDeviceID) -> Bool {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    return (try? propertyDataSize(deviceID, &address)) ?? 0 > 0
}

func outputDevice(named wantedName: String) throws -> AudioDeviceID {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let size = try propertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address)
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var devices = [AudioDeviceID](repeating: 0, count: count)
    var mutableSize = size
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &mutableSize,
        &devices
    )
    guard status == noErr else {
        throw HelperError.message("Could not enumerate CoreAudio devices (\(status))")
    }
    if let exact = devices.first(where: { hasOutputStreams($0) && deviceName($0) == wantedName }) {
        return exact
    }
    let available = devices.compactMap { hasOutputStreams($0) ? deviceName($0) : nil }.sorted()
    throw HelperError.message(
        "Virtual microphone output device '\(wantedName)' was not found. Available outputs: "
            + (available.isEmpty ? "none" : available.joined(separator: ", "))
    )
}

func defaultInputDevice() throws -> AudioDeviceID {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var deviceID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &size,
        &deviceID
    )
    guard status == noErr, deviceID != 0 else {
        throw HelperError.message("Could not read the default microphone (\(status))")
    }
    return deviceID
}

func setDefaultInputDevice(_ deviceID: AudioDeviceID) throws {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var selected = deviceID
    let status = AudioObjectSetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        UInt32(MemoryLayout<AudioDeviceID>.size),
        &selected
    )
    guard status == noErr else {
        throw HelperError.message("Could not select the virtual microphone (\(status))")
    }
}

func shortcutFlags(from raw: String) throws -> CGEventFlags {
    var flags: CGEventFlags = []
    for token in raw.lowercased().split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
        switch token {
        case "", "none": continue
        case "control", "ctrl": flags.insert(.maskControl)
        case "option", "alt": flags.insert(.maskAlternate)
        case "shift": flags.insert(.maskShift)
        case "command", "cmd": flags.insert(.maskCommand)
        case "fn": flags.insert(.maskSecondaryFn)
        default: throw HelperError.message("Unsupported shortcut modifier: \(token)")
        }
    }
    return flags
}

func postKey(keyCode: CGKeyCode, flags: CGEventFlags, keyDown: Bool) throws {
    guard let source = CGEventSource(stateID: .hidSystemState) else {
        throw HelperError.message("Could not create a HID keyboard event source")
    }
    guard let event = CGEvent(
        keyboardEventSource: source,
        virtualKey: keyCode,
        keyDown: keyDown
    ) else {
        throw HelperError.message("Could not create the WeChat Input shortcut event")
    }
    event.flags = keyDown ? flags : []
    event.post(tap: .cghidEventTap)
}

func postFnModifier(keyCode: CGKeyCode, flags: CGEventFlags, keyDown: Bool) throws {
    guard let source = CGEventSource(stateID: .hidSystemState) else {
        throw HelperError.message("Could not create a HID Fn event source")
    }
    guard let event = CGEvent(
        keyboardEventSource: source,
        virtualKey: keyCode,
        keyDown: keyDown
    ) else {
        throw HelperError.message("Could not create the WeChat Input Fn event")
    }
    // Fn is a modifier key. macOS reports it as flagsChanged rather than as a
    // normal keyDown/keyUp pair, which is what WeChat Input's hold-Fn monitor
    // listens for.
    event.type = .flagsChanged
    event.flags = keyDown ? flags.union(.maskSecondaryFn) : []
    event.post(tap: .cghidEventTap)
}

func tapShortcut(keyCode: CGKeyCode, flags: CGEventFlags) throws {
    try postKey(keyCode: keyCode, flags: flags, keyDown: true)
    usleep(30_000)
    try postKey(keyCode: keyCode, flags: flags, keyDown: false)
}

func play(_ audioURL: URL, through deviceID: AudioDeviceID) throws {
    let file = try AVAudioFile(forReading: audioURL)
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: nil)

    guard let audioUnit = engine.outputNode.audioUnit else {
        throw HelperError.message("CoreAudio output unit is unavailable")
    }
    var selectedDevice = deviceID
    let status = AudioUnitSetProperty(
        audioUnit,
        kAudioOutputUnitProperty_CurrentDevice,
        kAudioUnitScope_Global,
        0,
        &selectedDevice,
        UInt32(MemoryLayout<AudioDeviceID>.size)
    )
    guard status == noErr else {
        throw HelperError.message("Could not route audio to the virtual microphone (\(status))")
    }

    let completed = DispatchSemaphore(value: 0)
    // The default completion callback may run once AVAudioEngine has consumed
    // the scheduled buffers, before the final samples have actually reached
    // BlackHole. Waiting for dataPlayedBack keeps Fn held through the last
    // rendered sample so WeChat Input does not clip the final words.
    player.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { _ in
        completed.signal()
    }
    try engine.start()
    player.play()
    let duration = Double(file.length) / file.processingFormat.sampleRate
    let timeout = DispatchTime.now() + duration + 5.0
    guard completed.wait(timeout: timeout) == .success else {
        player.stop()
        engine.stop()
        throw HelperError.message("Timed out while feeding the virtual microphone")
    }
    player.stop()
    engine.stop()
}

func streamLivePCM() throws {
    let audioOnly = CommandLine.arguments.contains("--audio-only")
    guard audioOnly || AXIsProcessTrusted() else {
        throw HelperError.message("Accessibility permission is required to trigger WeChat Input")
    }
    let environment = ProcessInfo.processInfo.environment
    let previousInputSource = audioOnly ? nil : try selectWeChatInputSource()
    defer { restoreInputSource(previousInputSource) }
    let device = try outputDevice(
        named: environment["VIBE_STICK_EXTERNAL_INPUT_DEVICE"] ?? "BlackHole 2ch"
    )
    let keyCode = CGKeyCode(UInt16(environment["VIBE_STICK_EXTERNAL_INPUT_KEYCODE"] ?? "63") ?? 63)
    let flags = try shortcutFlags(
        from: environment["VIBE_STICK_EXTERNAL_INPUT_MODIFIERS"] ?? "fn"
    )
    let startDelay = max(0, min(2,
        Double(environment["VIBE_STICK_EXTERNAL_INPUT_START_DELAY"] ?? "0.35") ?? 0.35
    ))
    let stopDelay = max(0, min(2,
        Double(environment["VIBE_STICK_EXTERNAL_INPUT_STOP_DELAY"] ?? "0.8") ?? 0.8
    ))

    let previousInput: AudioDeviceID? = audioOnly ? nil : try defaultInputDevice()
    if !audioOnly { try setDefaultInputDevice(device) }
    defer { if let previousInput { try? setDefaultInputDevice(previousInput) } }

    let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: format)
    guard let audioUnit = engine.outputNode.audioUnit else {
        throw HelperError.message("CoreAudio output unit is unavailable")
    }
    var selectedDevice = device
    let routeStatus = AudioUnitSetProperty(
        audioUnit,
        kAudioOutputUnitProperty_CurrentDevice,
        kAudioUnitScope_Global,
        0,
        &selectedDevice,
        UInt32(MemoryLayout<AudioDeviceID>.size)
    )
    guard routeStatus == noErr else {
        throw HelperError.message("Could not route live audio to BlackHole (\(routeStatus))")
    }

    if !audioOnly { try postFnModifier(keyCode: keyCode, flags: flags, keyDown: true) }
    var fnHeld = !audioOnly
    defer {
        if fnHeld { try? postFnModifier(keyCode: keyCode, flags: flags, keyDown: false) }
    }
    if audioOnly { print("IPRC_AUDIO_READY"); fflush(stdout) }
    Thread.sleep(forTimeInterval: startDelay)
    try engine.start()
    player.play()

    let pending = DispatchGroup()
    while true {
        let data = FileHandle.standardInput.readData(ofLength: 16_000)
        if data.isEmpty { break }
        let frames = data.count / MemoryLayout<Int16>.size
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channel = buffer.int16ChannelData?[0]
        else { continue }
        buffer.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress { memcpy(channel, base, frames * 2) }
        }
        pending.enter()
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
            pending.leave()
        }
    }
    guard pending.wait(timeout: .now() + 8) == .success else {
        throw HelperError.message("Timed out draining the live WeChat audio stream")
    }
    Thread.sleep(forTimeInterval: stopDelay)
    if !audioOnly { try postFnModifier(keyCode: keyCode, flags: flags, keyDown: false) }
    fnHeld = false
    player.stop()
    engine.stop()
    print("WeChat Input consumed the live StickS3 stream")
}

do {
    if CommandLine.arguments.contains("--stream") {
        try streamLivePCM()
        exit(0)
    }
    let stdin = FileHandle.standardInput.readDataToEndOfFile()
    guard
        let payload = try JSONSerialization.jsonObject(with: stdin) as? [String: Any],
        let audioPath = payload["audio_file"] as? String,
        !audioPath.isEmpty
    else {
        throw HelperError.message("Recording session JSON has no audio_file")
    }
    guard FileManager.default.fileExists(atPath: audioPath) else {
        throw HelperError.message("Recording audio file does not exist")
    }
    guard AXIsProcessTrusted() else {
        throw HelperError.message(
            "Accessibility permission is required to trigger the WeChat Input shortcut"
        )
    }

    let environment = ProcessInfo.processInfo.environment
    let previousInputSource = try selectWeChatInputSource()
    defer { restoreInputSource(previousInputSource) }
    let device = try outputDevice(named: environment["VIBE_STICK_EXTERNAL_INPUT_DEVICE"] ?? "BlackHole 2ch")
    let shortcutMode = environment["VIBE_STICK_EXTERNAL_INPUT_SHORTCUT_MODE"] ?? "fn-hold"
    guard shortcutMode == "fn-hold" || shortcutMode == "toggle" else {
        throw HelperError.message("External-input shortcut mode must be fn-hold or toggle")
    }
    let keyCodeRaw = environment["VIBE_STICK_EXTERNAL_INPUT_KEYCODE"]
        ?? (shortcutMode == "fn-hold" ? "63" : "49")
    guard let keyCodeValue = UInt16(keyCodeRaw) else {
        throw HelperError.message("Invalid external-input shortcut key code")
    }
    let flags = try shortcutFlags(
        from: environment["VIBE_STICK_EXTERNAL_INPUT_MODIFIERS"]
            ?? (shortcutMode == "fn-hold" ? "fn" : "control,option")
    )
    let keyCode = CGKeyCode(keyCodeValue)
    let startDelay = max(0, min(2, Double(environment["VIBE_STICK_EXTERNAL_INPUT_START_DELAY"] ?? "0.35") ?? 0.35))
    let stopDelay = max(0, min(2, Double(environment["VIBE_STICK_EXTERNAL_INPUT_STOP_DELAY"] ?? "0.8") ?? 0.8))

    let previousInput = try defaultInputDevice()
    try setDefaultInputDevice(device)
    var needsInputRestore = true
    defer {
        if needsInputRestore {
            try? setDefaultInputDevice(previousInput)
        }
    }

    if shortcutMode == "fn-hold" {
        try postFnModifier(keyCode: keyCode, flags: flags, keyDown: true)
    } else {
        try tapShortcut(keyCode: keyCode, flags: flags)
    }
    var needsStop = true
    defer {
        if needsStop {
            if shortcutMode == "fn-hold" {
                try? postFnModifier(keyCode: keyCode, flags: flags, keyDown: false)
            } else {
                try? tapShortcut(keyCode: keyCode, flags: flags)
            }
        }
    }
    Thread.sleep(forTimeInterval: startDelay)
    try play(URL(fileURLWithPath: audioPath), through: device)
    Thread.sleep(forTimeInterval: stopDelay)
    if shortcutMode == "fn-hold" {
        try postFnModifier(keyCode: keyCode, flags: flags, keyDown: false)
    } else {
        try tapShortcut(keyCode: keyCode, flags: flags)
    }
    needsStop = false
    try setDefaultInputDevice(previousInput)
    needsInputRestore = false
    print("WeChat Input consumed the StickS3 recording")
} catch {
    fputs((error.localizedDescription + "\n"), stderr)
    exit(1)
}
