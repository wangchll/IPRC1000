import AppKit
import CoreGraphics
import IOKit.hidsystem

enum KeyEmitter {
    static func emit(_ binding: KeyBinding) {
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
                modifierKeys(binding.modifiers)
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

    private static func keyboard(_ code: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            event.flags = flags
            post(event)
        }
    }

    private static func modifierKeys(_ modifiers: Set<KeyModifier>) {
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
            event.type = .flagsChanged
            event.flags = flags
            post(event)
        }

        for modifier in ordered.reversed() {
            flags.remove(modifier.eventFlag)
            guard let event = CGEvent(
                keyboardEventSource: source,
                virtualKey: modifier.keyCode,
                keyDown: false
            ) else { continue }
            event.type = .flagsChanged
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
