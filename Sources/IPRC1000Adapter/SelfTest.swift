import CoreAudio
import Darwin
import Foundation
import IOKit.hid

@MainActor
enum SelfTest {
    static func run() -> Bool {
        var failures: [String] = []
        var speechSegments = SpeechSegments()
        let firstSpeech = speechSegments.begin()
        speechSegments.endInput()
        let secondSpeech = speechSegments.begin()
        check(speechSegments.complete(firstSpeech, text: "第一句").map { $0.1 } == ["第一句"]
              && speechSegments.current == secondSpeech,
              "late first speech final does not clear the next utterance", into: &failures)
        check(speechSegments.complete(firstSpeech, text: "重复").isEmpty,
              "duplicate speech finals do not insert twice", into: &failures)
        speechSegments.endInput()
        let thirdSpeech = speechSegments.begin()
        check(speechSegments.complete(thirdSpeech, text: "第三句").isEmpty
              && speechSegments.complete(secondSpeech, text: "第二句").map { $0.1 } == ["第二句", "第三句"],
              "out-of-order recognition finals are committed in speaking order", into: &failures)
        var committed: [Int] = []
        let commitQueue = SpeechCommitQueue()
        commitQueue.append { committed.append(1) }
        commitQueue.append { committed.append(2) }
        check(committed == [1], "speech finals cannot overwrite each other's pasteboard in one turn", into: &failures)
        let commitDeadline = Date(timeIntervalSinceNow: 2)
        while committed.count < 2 && Date() < commitDeadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        check(committed == [1, 2], "second speech final waits for pasteboard restoration", into: &failures)
        commitQueue.append { committed.append(3) }
        commitQueue.clear()
        commitQueue.append { committed.append(4) }
        let restartDeadline = Date(timeIntervalSinceNow: 2)
        while committed.count < 3 && Date() < restartDeadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        check(committed == [1, 2, 4], "disabling speech discards queued text before a new session", into: &failures)
        commitQueue.clear()
        let keyboardACL = "0\tHID Interrupt Receive\tAA-BB-CC-DD-EE-FF\tIPRC1000\t0x0021\tkeyboard\t21 20 0E 00 0A 00 41 00 A1 01 00 00 10 00 00 00 00 00"
        check(HCIVoiceLine.parse(keyboardACL, address: "AA-BB-CC-DD-EE-FF")?.report == [1, 0, 0, 0x10, 0, 0, 0, 0, 0],
              "HCI keyboard report uses validated ACL envelope", into: &failures)
        check(HCIVoiceLine.parse(keyboardACL, address: "00-11-22-33-44-55") == nil,
              "HCI keyboard from another device is rejected", into: &failures)
        check(HIDReportParser.usages(from: [1, 0, 0, 0x52, 0, 0, 0, 0, 0]) == [0x52],
              "HID report ID parsing", into: &failures)
        check(HIDReportParser.usages(from: [1, 0, 0, 0x0C, 0, 0, 0, 0, 0]).isEmpty,
              "spurious 0x0C filter", into: &failures)
        check(HIDReportParser.rawUsages(from: [1, 0, 0, 0x0C, 0, 0, 0, 0, 0]) == [0x0C],
              "raw spurious 0x0C capture", into: &failures)
        check(HIDReportParser.usages(from: [0, 0, 0x28, 0, 0, 0, 0, 0]) == [0x28],
              "HID payload parsing", into: &failures)
        check(TargetRemote.matches(
            vendorID: 0x0A5C, productID: 0x8502, productName: "IPRC1000"
        ), "target model matching", into: &failures)
        check(TargetRemote.matches(
            vendorID: 0x0A5C, productID: 0x8502, productName: "Broadcom Bluetooth Wireless Remote Control"
        ), "same-model product-name variation acceptance", into: &failures)
        check(!TargetRemote.matches(
            vendorID: 0x05AC, productID: 0x0342, productName: "Apple Keyboard"
        ), "other keyboard rejection", into: &failures)
        check(!TargetRemote.matches(
            vendorID: 0x0A5C, productID: 0x8503, productName: "IPRC1000"
        ), "other product rejection", into: &failures)
        let exactRemote = TargetRemote.exclusiveMatching(address: "aa-bb-cc-dd-ee-ff")
        check(exactRemote?[kIOHIDSerialNumberKey] as? String == "AA:BB:CC:DD:EE:FF"
              && exactRemote?[kIOHIDTransportKey] as? String == "Bluetooth"
              && exactRemote?[kIOHIDVendorIDKey] as? Int == TargetRemote.vendorID
              && exactRemote?[kIOHIDProductIDKey] as? Int == TargetRemote.productID
              && exactRemote?[kIOHIDProductKey] as? String == TargetRemote.productName,
              "prearmed exclusive manager is limited to the exact remote address and model", into: &failures)
        check(TargetRemote.exclusiveMatching(address: "") == nil
              && TargetRemote.exclusiveMatching(address: "AABBCCDDEE") == nil
              && TargetRemote.exclusiveMatching(address: "unknown:AABBCCDDEEFF") == nil,
              "exclusive manager refuses missing or malformed target identity", into: &failures)
        check(RemoteKey.allCases.allSatisfy {
            RemoteKeyCode.virtualKeyCode(for: $0.rawValue) != nil
        }, "all remote usages have source key codes", into: &failures)
        check(RemoteKeyCode.virtualKeyCode(for: 0x0C) == 34,
              "spurious i source key code", into: &failures)
        let artworkCanvas = CGRect(origin: .zero, size: RemoteKeyArtwork.canvasSize)
        check(RemoteKey.allCases.allSatisfy {
            artworkCanvas.contains(RemoteKeyArtwork.rect(for: $0))
        }, "all remote keys have in-bounds artwork regions", into: &failures)
        check(RemoteDeviceKeyFilter.matchesService(vendorID: 0x0A5C, productID: 0x8502,
            transport: "Bluetooth", deviceID: 111, expectedDeviceID: 111),
              "device mapping matches the validated physical instance", into: &failures)
        check(!RemoteDeviceKeyFilter.matchesService(vendorID: 0x0A5C, productID: 0x8502,
            transport: "Bluetooth", deviceID: 222, expectedDeviceID: 111),
              "same-model other remote is not modified", into: &failures)
        check(!RemoteDeviceKeyFilter.matchesService(vendorID: 0x05AC, productID: 0x0342,
            transport: "USB", deviceID: 111, expectedDeviceID: 111),
              "other keyboard service is not modified", into: &failures)
        check(!RemoteDeviceKeyFilter.matchesService(vendorID: 0x0A5C, productID: 0x8502,
            transport: "Bluetooth", deviceID: nil, expectedDeviceID: 111),
              "missing device identity fails closed", into: &failures)
        check(RemoteDeviceKeyFilter.mappings.count == RemoteKey.allCases.count + 1
              && RemoteDeviceKeyFilter.mappings.allSatisfy { $0["HIDKeyboardModifierMappingDst"] == 0 },
              "remote usages and spurious i are mapped to no action", into: &failures)

        let shortcut = KeyBinding.keyboard(
            1, modifiers: [.control, .option, .shift, .command, .function]
        )
        check(shortcut.title == "⌃⌥⇧⌘fnS", "five-modifier shortcut title", into: &failures)
        if let encoded = try? JSONEncoder().encode(shortcut),
           let decoded = try? JSONDecoder().decode(KeyBinding.self, from: encoded) {
            check(decoded == shortcut, "shortcut persistence round trip", into: &failures)
        } else {
            failures.append("shortcut persistence round trip")
        }
        let fnOnly = KeyBinding.modifierOnly([.function])
        check(fnOnly.title == "fn", "standalone Fn title", into: &failures)
        check(fnOnly.kind == .keyboard && fnOnly.keyCode == nil,
              "standalone Fn representation", into: &failures)
        check(KeyModifier.function.keyCode == 63, "standalone Fn key code", into: &failures)
        check(KeyModifier.function.eventType(isDown: true) == .flagsChanged
              && KeyModifier.function.eventType(isDown: false) == .flagsChanged,
              "standalone Fn uses flags changed events", into: &failures)
        check(KeyModifier.command.eventType(isDown: true) == .flagsChanged,
              "standard modifiers use flags changed events", into: &failures)
        check(shortcut.repeatsWhileHeld, "keyboard shortcut repeats while held", into: &failures)
        check(!fnOnly.repeatsWhileHeld, "standalone Fn remains held without repeat reports", into: &failures)
        check(fnOnly.requiresReleaseEvent, "standalone Fn keeps a release lifecycle", into: &failures)
        check(fnOnly.isFunctionOnly, "standalone Fn uses sticky lifecycle", into: &failures)
        check(!shortcut.requiresReleaseEvent, "keyboard shortcut does not use modifier release", into: &failures)
        check(KeyBinding.media(.volumeUp).repeatsWhileHeld,
              "volume media key repeats while held", into: &failures)
        check(!KeyBinding.media(.playPause).repeatsWhileHeld,
              "play pause does not repeat while held", into: &failures)
        check(HIDController.repeatingKey(for: 126, pressed: [0x52]) == .up,
              "held remote key resolves from suppressed repeat", into: &failures)
        check(HIDController.repeatingKey(for: 34, pressed: [0x0C]) == nil,
              "spurious i repeat is never translated", into: &failures)
        if let encoded = try? JSONEncoder().encode(fnOnly),
           let decoded = try? JSONDecoder().decode(KeyBinding.self, from: encoded) {
            check(decoded == fnOnly, "standalone Fn persistence round trip", into: &failures)
        } else {
            failures.append("standalone Fn persistence round trip")
        }
        check(MappingStore.defaults[.microphone] == KeyBinding.none,
              "microphone mapping defaults to unassigned", into: &failures)

        let suiteName = "local.iprc1000.adapter.selftest.\(UUID().uuidString)"
        if let defaults = UserDefaults(suiteName: suiteName) {
            defaults.set(Data(#"{"82":"arrowUp","6":"appSwitcher"}"#.utf8),
                         forKey: "keyMappings")
            let migrated = MappingStore(defaults: defaults)
            check(migrated.values[.up] == .keyboard(126),
                  "legacy arrow mapping migration", into: &failures)
            check(migrated.values[.last] == .keyboard(48, modifiers: [.command]),
                  "legacy shortcut mapping migration", into: &failures)
            check(migrated.activeProfile?.name == "默认配置组 1",
                  "legacy profile name migration", into: &failures)
            check(migrated.profiles.count == 2 && migrated.profiles[1].name == "Codex 编程",
                  "Codex programming profile seeding", into: &failures)
            check(MappingStore.codexDefaults[.menu] == .keyboard(35, modifiers: [.command, .shift])
                  && MappingStore.codexDefaults[.home] == .keyboard(45, modifiers: [.command])
                  && MappingStore.codexDefaults[.heart] == .keyboard(1, modifiers: [.command]),
                  "Codex programming shortcuts", into: &failures)
            check(migrated.selectNextProfile() == "Codex 编程"
                  && migrated.activeProfile?.name == "Codex 编程",
                  "reserved key advances to Codex profile", into: &failures)
            check(migrated.selectNextProfile() == "默认配置组 1"
                  && migrated.activeProfile?.name == "默认配置组 1",
                  "reserved key wraps to first profile", into: &failures)
            migrated.addProfile()
            check(migrated.activeProfile?.name == "默认配置组 2",
                  "automatic profile naming", into: &failures)
            let secondProfileID = migrated.activeProfileID
            migrated.renameProfile(secondProfileID, to: "演示")
            check(migrated.activeProfile?.name == "演示",
                  "profile renaming", into: &failures)
            migrated.values[.heart] = shortcut
            let firstProfileID = migrated.profiles[0].id
            migrated.selectProfile(firstProfileID)
            check(migrated.values[.heart] == KeyBinding.none,
                  "profile switching restores bindings", into: &failures)
            migrated.selectProfile(secondProfileID)
            check(migrated.values[.heart] == shortcut,
                  "profile switching preserves bindings", into: &failures)
            let reloaded = MappingStore(defaults: defaults)
            check(reloaded.profiles.count == 3 && reloaded.values[.heart] == shortcut,
                  "profile collection persistence", into: &failures)
            if let exported = try? migrated.exportActiveProfileData() {
                let importSuite = "local.iprc1000.adapter.importtest.\(UUID().uuidString)"
                if let importDefaults = UserDefaults(suiteName: importSuite) {
                    let destination = MappingStore(defaults: importDefaults)
                    try? destination.importIntoActiveProfile(exported)
                    check(destination.profiles.count == 2 && destination.values[.heart] == shortcut,
                          "active profile export and replacement import", into: &failures)
                    check(destination.activeProfile?.name == "默认配置组 1",
                          "import preserves selected profile name", into: &failures)
                    importDefaults.removePersistentDomain(forName: importSuite)
                } else {
                    failures.append("configuration import test defaults")
                }
            } else {
                failures.append("configuration export")
            }
            defaults.removePersistentDomain(forName: suiteName)
        } else {
            failures.append("legacy mapping test defaults")
        }
        let microphoneMap = [String(RemoteKey.microphone.rawValue): shortcut]
        if let data = try? JSONEncoder().encode(microphoneMap),
           let decoded = try? JSONDecoder().decode([String: KeyBinding].self, from: data) {
            check(decoded[String(RemoteKey.microphone.rawValue)] == shortcut,
                  "microphone custom shortcut persistence", into: &failures)
        } else {
            failures.append("microphone custom shortcut persistence")
        }

        let bytes = hex("""
            01 08 AD 00 00 37 65 54 34 33 7D DD AD 5F 77 6B 57 DD DA D5
            F7 76 B5 7D DD AD 5F 77 6B 57 5D DA D5 A9 74 B9 29 A5 92 09
            59 6B A1 71 DD 90 B4 55 51 32 21 0A 94 77 33 12 9A DC D4 00
            """)
        var state = VoicePacketAssembler.State()
        _ = VoicePacketAssembler.append(Array(bytes[0..<20]), to: &state)
        _ = VoicePacketAssembler.append(Array(bytes[20..<40]), to: &state)
        let frame = VoicePacketAssembler.append(Array(bytes[40..<60]), to: &state)
        check(frame?.count == 57 && frame?.prefix(4) == [0xAD, 0x00, 0x00, 0x37],
              "three-packet mSBC assembly", into: &failures)
        if let frame, let decoder = MSBCDecoder() {
            check(decoder.decode(frame)?.count == 120,
                  "official mSBC sample decodes to 120 samples", into: &failures)
        } else {
            failures.append("mSBC decoder initialization")
        }

        var adpcm = [UInt8](repeating: 0, count: 134)
        adpcm[5] = 0
        let adpcmPCM = GoogleVoiceADPCM.decode(adpcm)
        check(adpcmPCM?.count == 256 && adpcmPCM?.allSatisfy { $0 == 0 } == true,
              "Google Voice ADPCM packet decoding", into: &failures)

        final class CapturedKeys: @unchecked Sendable {
            var down: [RemoteKey] = []
            var up: [RemoteKey] = []
        }
        let captured = CapturedKeys()
        let exclusiveHID = HIDController()
        exclusiveHID.onKey = { captured.down.append($0) }
        exclusiveHID.onKeyUp = { captured.up.append($0) }
        let micReport: [UInt8] = [1, 0, 0, 0x10, 0, 0, 0, 0, 0]
        exclusiveHID.receiveExclusiveKeyboard(micReport)
        check(captured.down.isEmpty, "unowned raw input is rejected", into: &failures)
        exclusiveHID.exclusiveConnectionChanged(true)
        exclusiveHID.receiveExclusiveKeyboard(micReport)
        exclusiveHID.receiveExclusiveKeyboard(micReport)
        exclusiveHID.receiveExclusiveKeyboard([1, 0, 0, 1, 1, 1, 1, 1, 1])
        exclusiveHID.receiveExclusiveKeyboard([1, 0, 0, 2, 2, 2, 2, 2, 2])
        exclusiveHID.receiveExclusiveKeyboard([1, 0, 0, 3, 3, 3, 3, 3, 3])
        exclusiveHID.receiveExclusiveKeyboard(micReport)
        exclusiveHID.receiveExclusiveKeyboard([0xF7, 1])
        check(captured.down == [.microphone] && captured.up.isEmpty && exclusiveHID.prepareDeviceFilter(),
              "rollover and malformed reports do not release or retrigger the held microphone", into: &failures)
        exclusiveHID.exclusiveConnectionChanged(false)
        exclusiveHID.receiveExclusiveKeyboard(micReport)
        check(captured.up == [.microphone] && captured.down.count == 1 && !exclusiveHID.prepareDeviceFilter(),
              "exclusive disconnect releases key once and rejects stale reports", into: &failures)
        var controlPipe: [Int32] = [-1, -1]
        if pipe(&controlPipe) == 0 {
            let protected = fcntl(controlPipe[1], F_SETNOSIGPIPE, 1) == 0
            close(controlPipe[0])
            if protected {
                var byte: UInt8 = 82
                let result = Darwin.write(controlPipe[1], &byte, 1)
                check(result == -1 && errno == EPIPE,
                      "retrying a closed helper returns EPIPE without killing the adapter", into: &failures)
            } else { failures.append("control pipe SIGPIPE protection") }
            close(controlPipe[1])
        } else { failures.append("control pipe creation") }
        var outputPipe: [Int32] = [-1, -1]
        if pipe(&outputPipe) == 0 {
            _ = fcntl(outputPipe[0], F_SETFL, O_NONBLOCK)
            _ = fcntl(outputPipe[1], F_SETFL, O_NONBLOCK)
            let protected = fcntl(outputPipe[1], F_SETNOSIGPIPE, 1) == 0
            var filler = [UInt8](repeating: 0x58, count: 4096)
            while Darwin.write(outputPipe[1], &filler, filler.count) > 0 {}
            var byte: UInt8 = 0x58
            while Darwin.write(outputPipe[1], &byte, 1) > 0 {}
            let full = errno == EAGAIN
            let messages = "I 1\nK 010000100000000000\nK 010000000000000000\n"
            var output = CaptureOutputBuffer()
            let accepted = output.append("I 1")
                && output.append("K 010000100000000000")
                && output.append("K 010000000000000000")
            check(full && accepted && output.flush(to: outputPipe[1])
                  && output.queuedBytes == messages.utf8.count,
                  "full foreground pipe retains target ownership and pending key transitions", into: &failures)
            while Darwin.read(outputPipe[0], &filler, filler.count) > 0 {}
            let flushed = output.flush(to: outputPipe[1])
            let count = Darwin.read(outputPipe[0], &filler, filler.count)
            check(flushed && output.queuedBytes == 0 && count == messages.utf8.count
                  && Data(filler.prefix(max(0, count))) == Data(messages.utf8),
                  "slow foreground recovery delivers key transitions in order without loss", into: &failures)
            close(outputPipe[0])
            if protected {
                _ = output.append("I 0")
                check(!output.flush(to: outputPipe[1]) && errno == EPIPE,
                      "real foreground disconnect is distinguished from backpressure", into: &failures)
            } else { failures.append("capture output SIGPIPE protection") }
            close(outputPipe[1])
        } else { failures.append("capture output pipe creation") }
        var captureLines = BoundedCaptureLines()
        check(captureLines.append(Data("F 21".utf8)).isEmpty
              && captureLines.append(Data(" payload\nI 1\n".utf8)) == ["F 21 payload", "I 1"],
              "capture line framing preserves partial and multiple messages", into: &failures)
        check(captureLines.append(Data(repeating: 65, count: 65537)).isEmpty
              && captureLines.append(Data("discarded\nI 1\n".utf8)) == ["I 1"],
              "oversized unrelated line does not kill capture or poison the next message", into: &failures)
        if case .audioReset = CaptureMessage.parse("A 0") {} else {
            failures.append("audio restart notification is distinct from losing target isolation")
        }
        if case .audioMode(false) = CaptureMessage.parse("M 0"),
           case .audioMode(true) = CaptureMessage.parse("M 1") {} else {
            failures.append("optional audio mode is distinct from keyboard isolation")
        }
        check(CaptureMessage.parse("M 2") == nil
              && CaptureCommand(rawValue: 65) == .startAudio
              && CaptureCommand(rawValue: 83) == .stopAudio
              && CaptureCommand(rawValue: 82) == .retryAudio
              && CaptureCommand(rawValue: 0) == nil,
              "only fixed audio lifecycle commands are accepted", into: &failures)
        check(CaptureFailure.message(-1001).contains("按键接管可独立")
              && CaptureFailure.message(-1003).contains("签名")
              && CaptureFailure.message(-1002).contains("通信")
              && CaptureFailure.message(-60006).contains("取消"),
              "missing tools, signature, IPC and cancelled authorization have distinct guidance", into: &failures)
        var diagnosticWindow = ExclusiveDiagnosticWindow(start: 0)
        check(!diagnosticWindow.expired(at: 120) && !diagnosticWindow.expired(at: 899)
              && diagnosticWindow.expired(at: 900),
              "device wait has its own bounded window", into: &failures)
        diagnosticWindow.keyboard(micReport, at: 899)
        check(!diagnosticWindow.expired(at: 900) && !diagnosticWindow.expired(at: 1018)
              && diagnosticWindow.expired(at: 1019),
              "late microphone press still gets full capture window", into: &failures)
        diagnosticWindow.keyboard(micReport, at: 1000)
        check(diagnosticWindow.expired(at: 1019),
              "repeated microphone reports do not extend capture indefinitely", into: &failures)
        var releasedWindow = ExclusiveDiagnosticWindow(start: 0)
        releasedWindow.keyboard(micReport, at: 700)
        releasedWindow.keyboard([1,0,0,0,0,0,0,0,0], at: 705)
        check(!releasedWindow.expired(at: 706.9) && releasedWindow.expired(at: 707),
              "diagnostic captures complete press and trailing reports", into: &failures)
        var directionWindow = ExclusiveDiagnosticWindow(start: 0)
        directionWindow.keyboard([1,0,0,0x52,0,0,0,0,0], at: 100)
        check(directionWindow.captureDeadline == nil && !directionWindow.expired(at: 899),
              "direction-key wake does not spend the microphone capture window", into: &failures)
        let disconnectedHID = HIDController()
        check(!disconnectedHID.prepareDeviceFilter() && !disconnectedHID.maintainDeviceFilter(),
              "disconnected device never authorizes synthetic input", into: &failures)
        let unavailableInput = ExternalVoiceInput()
        unavailableInput.onBeforeFn = { false }
        for binding in [KeyBinding.modifierOnly([.function]), KeyBinding.keyboard(49, modifiers: [.control])] {
            for toggle in [false, true] {
                let message = unavailableInput.begin(shortcut: binding, toggle: toggle)
                check(!unavailableInput.active && message.contains("未启动"),
                      "unavailable input cannot start helper or custom shortcut", into: &failures)
            }
        }
        testClassicVoice(into: &failures)

        if failures.isEmpty {
            print("SELF-TEST PASS: model isolation, device mapping, HID/voice decoders, custom shortcuts and legacy mapping migration")
            return true
        }
        for failure in failures { FileHandle.standardError.write(Data("SELF-TEST FAIL: \(failure)\n".utf8)) }
        return false
    }

    private static func testClassicVoice(into failures: inout [String]) {
        // Synthetic protocol fixtures, matching the observed header and sample layout.
        func report(_ sequence: UInt16) -> [UInt8] {
            var bytes: [UInt8] = [0xF7, 1, UInt8(sequence & 255), UInt8(sequence >> 8),
                                  2, 0, 3, 0, 1, 0, 0x40, 1]
            for index in 0..<320 {
                let value = UInt16(bitPattern: Int16(index - 160))
                bytes += [UInt8(value & 255), UInt8(value >> 8)]
            }
            return bytes
        }
        let bytes = report(65535)
        var readiness = DeviceVoiceReadiness()
        check(!readiness.received(bytes, reportID: 0xF7, from: 11),
              "audio rejected without matched connection", into: &failures)
        readiness.connected(11)
        check(!readiness.audioReceived, "subscription is not audio readiness", into: &failures)
        check(!readiness.received([1, 0, 0, 0x10, 0, 0, 0, 0, 0], reportID: 1, from: 11)
              && !readiness.received(Array(bytes.dropLast()), reportID: 0xF7, from: 11)
              && !readiness.received(bytes, reportID: 0xF7, from: 12)
              && !readiness.audioReceived,
              "keyboard, malformed audio and other devices cannot enable voice", into: &failures)
        check(readiness.received(bytes, reportID: 0xF7, from: 11) && readiness.audioReceived,
              "only validated F7 enables audio availability", into: &failures)
        readiness.disconnected(12)
        check(readiness.audioReceived, "unrelated removal cannot reset target audio", into: &failures)
        readiness.disconnected(11)
        check(!readiness.audioReceived && !readiness.received(bytes, reportID: 0xF7, from: 11),
              "disconnect invalidates audio and rejects late reports", into: &failures)
        readiness.connected(12)
        check(!readiness.audioReceived && !readiness.received(bytes, reportID: 0xF7, from: 11),
              "reconnect requires fresh F7 from new device instance", into: &failures)
        let address = "00:11:22:33:44:55"
        let acl: [UInt8] = [0x15, 0x20, 0x91, 0x02, 0x8D, 0x02, 0x40, 0x00, 0xA1] + bytes
        let raw = acl.map { String(format: "%02X", $0) }.joined(separator: " ")
        let line = "time\tHID Interrupt Receive\t\(address)\tIPRC1000\t0x0015\tF7\t\(raw)"
        check(HCIVoiceLine.parse(line, address: address)?.report == bytes,
              "HCI validates target, receive direction and complete F7 envelope", into: &failures)
        check(HCIVoiceLine.parse(line + "\t", address: address)?.report == bytes,
              "HCI accepts Apple's trailing tab column delimiter", into: &failures)
        check(HCIVoiceLine.parse(line.replacingOccurrences(of: "\tIPRC1000\t", with: "\t\(address)\t"), address: address)?.report == bytes,
              "HCI accepts live display-name alias for the strictly matched paired address", into: &failures)
        check(HCIVoiceLine.parse(line, address: "00:11:22:33:44:56") == nil
              && HCIVoiceLine.parse(line.replacingOccurrences(of: "Receive", with: "Send"), address: address) == nil
              && HCIVoiceLine.parse(line.replacingOccurrences(of: "0x0015", with: "0x0016"), address: address) == nil
              && HCIVoiceLine.parse(line.replacingOccurrences(of: "91 02 8D", with: "90 02 8D"), address: address) == nil,
              "HCI rejects other remote, outgoing traffic, handle and length mismatch", into: &failures)
        if case .voice(let decoded, let handle) = CaptureMessage.parse("F 21 " + Data(bytes).base64EncodedString()) {
            check(decoded == bytes && handle == 21, "filtered capture wire round trip", into: &failures)
        } else { failures.append("filtered capture wire round trip") }
        check(CaptureMessage.parse("F 4096 " + Data(bytes).base64EncodedString()) == nil
              && CaptureMessage.parse("F 21 !!!") == nil
              && CaptureMessage.parse("K F70100000000000000") == nil
              && CaptureMessage.parse("I 2") == nil,
              "capture wire rejects malformed frame, handle, keyboard and isolation state", into: &failures)
        if case .keyboard(let report) = CaptureMessage.parse("K 010000100000000000") {
            check(report == [1,0,0,0x10,0,0,0,0,0], "capture wire keyboard frame", into: &failures)
        } else { failures.append("capture wire keyboard frame") }
        var watermark = HCIFrameWatermark()
        check(!watermark.canResumeBuffered && !watermark.accept(timestamp: "invalid", handle: 21, report: bytes),
              "buffered audio is disabled until a valid live watermark exists", into: &failures)
        check(watermark.accept(timestamp: "2026-11-02T10:00:00.100Z", handle: 21, report: bytes)
              && watermark.canResumeBuffered
              && !watermark.accept(timestamp: "2026-11-02T10:00:00.100Z", handle: 21, report: bytes)
              && !watermark.accept(timestamp: "2026-11-02T10:00:00.099Z", handle: 22, report: bytes),
              "capture restart never replays old or duplicated audio", into: &failures)
        check(watermark.accept(timestamp: "2026-11-02T10:00:00.100Z", handle: 21, report: report(0))
              && watermark.accept(timestamp: "2026-11-02T10:00:00.101Z", handle: 22, report: bytes),
              "equal-time distinct frames and newer reconnected frames are retained", into: &failures)
        let frame = ClassicVoiceFrame.parse(bytes, reportID: 0xF7)!
        check(frame.sequence == 65535 && frame.reserved == 1 && frame.deviceTime == 2
              && frame.bufferState == 3 && frame.samples.first == -160 && frame.samples.last == 159,
              "Classic F7 LE header, signed PCM and nonzero reserved", into: &failures)
        check(ClassicVoiceFrame.parse(Array(bytes.dropFirst()), reportID: 0xF7)?.samples == frame.samples,
              "Classic F7 callback without report ID", into: &failures)
        check(ClassicVoiceFrame.parse(bytes, reportID: 1) == nil
              && ClassicVoiceFrame.parse(Array(bytes.dropLast()), reportID: 0xF7) == nil
              && ClassicVoiceFrame.parse([0xA1] + bytes, reportID: 0xF7) == nil,
              "Classic F7 rejects wrong report ID, length and HIDP envelope", into: &failures)
        for offset in [1, 10, 11] {
            var bad = bytes
            bad[offset] = 0
            check(ClassicVoiceFrame.parse(bad, reportID: 0xF7) == nil,
                  "Classic F7 rejects invalid format/count at \(offset)", into: &failures)
        }
        func parsed(_ sequence: UInt16) -> ClassicVoiceFrame {
            ClassicVoiceFrame.parse(report(sequence), reportID: 0xF7)!
        }
        var stream = ClassicVoiceStream()
        check(stream.append(frame, at: 0)?.samples.count == 320,
              "Classic segment starts without leading silence", into: &failures)
        check(stream.append(parsed(0), at: 0.02)?.restarted == false,
              "Classic UInt16 rollover", into: &failures)
        check(stream.append(parsed(0), at: 0.03) == nil,
              "Classic duplicate rejection", into: &failures)
        check(stream.append(parsed(2), at: 0.04)?.samples.prefix(320).allSatisfy { $0 == 0 } == true
              && stream.missing == 1,
              "Classic bounded missing-frame silence", into: &failures)
        check(stream.append(parsed(1), at: 0.05) == nil,
              "Classic out-of-order rejection", into: &failures)
        check(stream.append(parsed(100), at: 0.06)?.samples.count == 320
              && stream.resynchronized == 1,
              "Classic large gap resynchronizes without long silence", into: &failures)
        check(stream.append(parsed(0), at: 0.07)?.restarted == true,
              "Classic new press restarts sequence", into: &failures)
        check(stream.append(parsed(70), at: 1)?.samples.count == 320,
              "Classic idle segment starts at nonzero sequence", into: &failures)
        stream.reset()
        check(stream.append(parsed(5), at: 1.02)?.restarted == true && stream.missing == 0,
              "Classic connection generation reset", into: &failures)

        let ring = FloatRingBuffer(capacity: 3)
        ring.write([1, 2, 3, 4])
        var stereo = [Float](repeating: -1, count: 8)
        stereo.withUnsafeMutableBytes { storage in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 2, mDataByteSize: UInt32(storage.count), mData: storage.baseAddress
            ))
            ring.render(&list)
        }
        check(stereo == [2, 2, 3, 3, 4, 4, 0, 0],
              "Classic bounded queue duplicates stereo and fills underrun with silence", into: &failures)
        ring.write([1, 2])
        ring.reset()
        stereo.withUnsafeMutableBytes { storage in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 2, mDataByteSize: UInt32(storage.count), mData: storage.baseAddress
            ))
            ring.render(&list)
        }
        check(stereo.allSatisfy { $0 == 0 }, "Classic disconnect clears queued audio", into: &failures)

        for rate in [44100.0, 48000.0] {
            let input = (0..<960).map { Int16($0 - 480) }
            var whole = VoiceResampler()
            let expected = whole.process(input, sampleRate: rate)
            var split = VoiceResampler()
            var actual: [Float] = []
            for index in stride(from: 0, to: input.count, by: 320) {
                actual += split.process(Array(input[index..<index + 320]), sampleRate: rate)
            }
            check(actual.count == expected.count
                  && zip(actual, expected).allSatisfy { abs($0 - $1) < 0.000001 },
                  "Classic continuous resampling at \(rate)", into: &failures)
            split.reset()
            check(split.process([-32768, 0], sampleRate: rate).first == -1,
                  "Classic signed Float scale and resampler reset", into: &failures)
        }
    }

    private static func check(_ condition: Bool, _ label: String, into failures: inout [String]) {
        if !condition { failures.append(label) }
    }

    private static func hex(_ value: String) -> [UInt8] {
        value.split(whereSeparator: { $0.isWhitespace }).compactMap { UInt8($0, radix: 16) }
    }
}
