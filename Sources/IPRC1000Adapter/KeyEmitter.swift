import AppKit
import CoreGraphics
import IOKit.hidsystem
import os

enum KeyEmitter {
    static let functionVirtualKey: CGKeyCode = 63
    private static let logger = Logger(subsystem: "local.iprc1000.adapter", category: "KeyEmitter")
    static func emit(_ binding: KeyBinding) {
        if binding.isFunctionOnly {
            functionEvent(isDown: true)
            return
        }
        switch binding.kind {
        case .none:
            return
        case .keyboard:
            if let keyCode = binding.keyCode {
                let flags = binding.modifiers.reduce(CGEventFlags()) {
                    $0.union($1.eventFlag)
                }
                keyboard(CGKeyCode(keyCode), flags: flags)
            } else {
                modifierKeysDown(binding.modifiers)
            }
        case .media:
            switch binding.mediaKey {
            case .playPause: media(NX_KEYTYPE_PLAY)
            case .nextTrack: media(NX_KEYTYPE_NEXT)
            case .previousTrack: media(NX_KEYTYPE_PREVIOUS)
            case .volumeUp: media(NX_KEYTYPE_SOUND_UP)
            case .volumeDown: media(NX_KEYTYPE_SOUND_DOWN)
            case .mute: media(NX_KEYTYPE_MUTE)
            case nil: return
            }
        }
    }

    static func emitRepeat(_ binding: KeyBinding) {
        guard binding.repeatsWhileHeld else { return }
        emit(binding)
    }

    static func release(_ binding: KeyBinding) {
        guard binding.requiresReleaseEvent else { return }
        if binding.isFunctionOnly {
            functionEvent(isDown: false)
            return
        }
        modifierKeysUp(binding.modifiers)
    }

    private static func functionEvent(isDown: Bool) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(
            keyboardEventSource: source,
            virtualKey: functionVirtualKey,
            keyDown: false
        ) else { return }
        event.type = .flagsChanged
        event.flags = isDown ? .maskSecondaryFn : []
        logger.notice("synthetic Fn flagsChanged down=\(isDown, privacy: .public) keyCode=63")
        post(event)
    }

    private static func keyboard(_ code: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            event.flags = flags
            post(event)
        }
    }

    private static func modifierKeysDown(_ modifiers: Set<KeyModifier>) {
        let ordered = KeyModifier.allCases.filter { modifiers.contains($0) }
        let source = CGEventSource(stateID: .hidSystemState)
        var flags = CGEventFlags()

        for modifier in ordered {
            flags.insert(modifier.eventFlag)
            guard let event = CGEvent(
                keyboardEventSource: source,
                virtualKey: modifier.keyCode,
                keyDown: true
            ) else { continue }
            event.type = modifier.eventType(isDown: true)
            event.flags = flags
            post(event)
        }
    }

    private static func modifierKeysUp(_ modifiers: Set<KeyModifier>) {
        let ordered = KeyModifier.allCases.filter { modifiers.contains($0) }
        let source = CGEventSource(stateID: .hidSystemState)
        var flags = modifiers.reduce(CGEventFlags()) { $0.union($1.eventFlag) }
        for modifier in ordered.reversed() {
            flags.remove(modifier.eventFlag)
            guard let event = CGEvent(
                keyboardEventSource: source,
                virtualKey: modifier.keyCode,
                keyDown: false
            ) else { continue }
            event.type = modifier.eventType(isDown: false)
            event.flags = flags
            post(event)
        }
    }

    private static func post(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: RemoteEventFilter.syntheticMarker)
        event.post(tap: .cghidEventTap)
    }

    private static func media(_ key: Int32) {
        for down in [true, false] {
            let flags = down ? 0xA : 0xB
            let data1 = Int((key << 16) | Int32(flags << 8))
            let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: down ? [] : .deviceIndependentFlagsMask,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: Int16(NX_SUBTYPE_AUX_CONTROL_BUTTONS),
                data1: data1,
                data2: -1
            )?.cgEvent
            event?.setIntegerValueField(.eventSourceUserData, value: RemoteEventFilter.syntheticMarker)
            event?.post(tap: .cghidEventTap)
        }
    }
}
