import CoreGraphics
import Foundation
import IOKit.hid
import IOBluetooth
import os

enum TargetRemote {
    static let vendorID = 0x0A5C
    static let productID = 0x8502
    static let productName = "IPRC1000"

    static func matches(vendorID: Int?, productID: Int?, productName: String?) -> Bool {
        vendorID == self.vendorID
            && productID == self.productID
    }

    static func matches(_ device: IOHIDDevice) -> Bool {
        matches(
            vendorID: numberProperty(device, key: kIOHIDVendorIDKey),
            productID: numberProperty(device, key: kIOHIDProductIDKey),
            productName: stringProperty(device, key: kIOHIDProductKey)
        )
    }

    static func normalizedAddress(_ value: String) -> String {
        value.uppercased().filter { $0.isHexDigit }
    }

    static func matchesVoice(_ device: IOHIDDevice, expectedAddress: String? = nil) -> Bool {
        guard matches(device), stringProperty(device, key: kIOHIDProductKey) == productName,
              stringProperty(device, key: kIOHIDTransportKey) == "Bluetooth",
              let serial = stringProperty(device, key: kIOHIDSerialNumberKey) else { return false }
        let normalized = normalizedAddress(serial)
        if let expectedAddress {
            let expected = normalizedAddress(expectedAddress)
            return expected.count == 12 && normalized.count == 12 && normalized == expected
        }
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? [])
            .filter { $0.name == productName }
        guard paired.count == 1, let address = paired.first?.addressString else { return false }
        return normalized.count == 12 && normalized == normalizedAddress(address)
    }

    static func exclusiveMatching(address: String) -> [String: Any]? {
        guard address.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "-" }) else { return nil }
        let bytes = Array(normalizedAddress(address))
        guard bytes.count == 12 else { return nil }
        let serial = stride(from: 0, to: 12, by: 2).map { String(bytes[$0...$0+1]) }.joined(separator: ":")
        return [kIOHIDVendorIDKey: vendorID, kIOHIDProductIDKey: productID,
                kIOHIDProductKey: productName, kIOHIDTransportKey: "Bluetooth", kIOHIDSerialNumberKey: serial]
    }

    private static func numberProperty(_ device: IOHIDDevice, key: String) -> Int? {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
    }

    private static func stringProperty(_ device: IOHIDDevice, key: String) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }
}

private func hidMatched(_ context: UnsafeMutableRawPointer?, _ result: IOReturn,
                        _ sender: UnsafeMutableRawPointer?, _ device: IOHIDDevice) {
    guard let context else { return }
    Unmanaged<HIDController>.fromOpaque(context).takeUnretainedValue().matched(device)
}

private func hidRemoved(_ context: UnsafeMutableRawPointer?, _ result: IOReturn,
                        _ sender: UnsafeMutableRawPointer?, _ device: IOHIDDevice) {
    guard let context else { return }
    Unmanaged<HIDController>.fromOpaque(context).takeUnretainedValue().removed(device)
}

private func hidReport(_ context: UnsafeMutableRawPointer?, _ result: IOReturn,
                       _ sender: UnsafeMutableRawPointer?, _ type: IOHIDReportType,
                       _ reportID: UInt32, _ report: UnsafeMutablePointer<UInt8>,
                       _ reportLength: CFIndex, _ timestamp: UInt64) {
    guard let context else { return }
    let controller = Unmanaged<HIDController>.fromOpaque(context).takeUnretainedValue()
    guard controller.noteCallback(result: result, type: type, sender: sender,
                                  reportID: reportID, length: reportLength) else { return }
    controller.receivedReport(
            Array(UnsafeBufferPointer(start: report, count: reportLength)),
            reportID: Int(reportID), timestamp: timestamp
        )
}

final class HIDController: @unchecked Sendable {
    private static let logger = Logger(subsystem: "local.iprc1000.adapter", category: "HIDReport")
    var onStatus: @Sendable (String, Bool) -> Void = { _, _ in }
    var onKey: @Sendable (RemoteKey) -> Void = { _ in }
    var onKeyRepeat: @Sendable (RemoteKey) -> Void = { _ in }
    var onKeyUp: @Sendable (RemoteKey) -> Void = { _ in }

    var onKeyboardReport: @Sendable ([UInt8]) -> Void = { _ in }
    private var wantsExclusive = false
    private var expectedAddress: String?
    var onVoiceReport: @Sendable ([UInt8], Int) -> Void = { _, _ in }
    var onVoiceConnection: @Sendable (Bool) -> Void = { _ in }
    var onInputDiagnostics: @Sendable (String) -> Void = { _ in }
    private var keyboardReports = 0
    private var voiceReports = 0
    private var callbackErrors = 0
    private var reportIDs: Set<UInt32> = []
    private var lastDiagnosticsTime = 0.0
    private var lastCallbackError: String?

    private let reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
    private var voiceTarget = false
    private var exclusiveReports = false
    private var keyFilteringReady = false
    private var lastFilterStatus = ""

    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private let deviceFilter = RemoteDeviceKeyFilter()
    private var filterTimer: Timer?
    private var repeatTimer: Timer?
    private var repeatAfter: TimeInterval = 0
    private var pressed: Set<UInt8> = []
    private var currentDevice: IOHIDDevice?
    private var managerOpened = false

    deinit { stop(); reportBuffer.deallocate() }

    func stop() {
        filterTimer?.invalidate(); filterTimer = nil
        repeatTimer?.invalidate(); repeatTimer = nil
        deviceFilter.restore()
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        if let currentDevice {
            IOHIDDeviceRegisterInputReportWithTimeStampCallback(currentDevice, reportBuffer, 4096, nil, nil)
            IOHIDDeviceUnscheduleFromRunLoop(currentDevice, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDDeviceClose(currentDevice, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        if managerOpened {
            Self.logger.notice("closing target exclusive manager")
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            managerOpened = false
        }
        currentDevice = nil
        exclusiveReports = false
        releasePressedKeys()
        keyFilteringReady = false
    }

    func startExclusive(address: String? = nil) {
        wantsExclusive = true
        expectedAddress = address
        start()
    }

    func start() {
        var matching: [String: Any] = [
            kIOHIDVendorIDKey as String: TargetRemote.vendorID,
            kIOHIDProductIDKey as String: TargetRemote.productID
        ]
        if wantsExclusive {
            guard let expectedAddress, let exact = TargetRemote.exclusiveMatching(address: expectedAddress) else {
                onStatus("独占接管需要明确的目标遥控器地址", false)
                return
            }
            matching = exact
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        if wantsExclusive {
            IOHIDManagerRegisterInputReportWithTimeStampCallback(manager, hidReport, context)
        }
        IOHIDManagerRegisterDeviceMatchingCallback(manager, hidMatched, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, hidRemoved, context)
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        // Exclusive matching pins the physical address before enumeration, so
        // reconnecting devices are seized before the user matching callback.
        onStatus("等待已配对 IPRC1000（0A5C:8502）", false)
        startRepeatTimer()
        if wantsExclusive {
            let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
            // IOHIDManager remains open even when opening an existing device fails.
            managerOpened = true
            Self.logger.notice("target exclusive manager armed result=\(result)")
            if result != kIOReturnSuccess { onStatus("目标独占管理器打开失败（\(result)）", false) }
        }
    }

    private func startRepeatTimer() {
        repeatTimer?.invalidate()
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            guard let self, self.keyFilteringReady,
                  ProcessInfo.processInfo.systemUptime >= self.repeatAfter else { return }
            for usage in self.pressed where usage != 0x0C {
                if let key = RemoteKey(rawValue: usage) { self.onKeyRepeat(key) }
            }
        }
    }

    fileprivate func matched(_ device: IOHIDDevice) {
        guard currentDevice == nil, TargetRemote.matchesVoice(device, expectedAddress: expectedAddress) else { return }
        let options = IOOptionBits(wantsExclusive ? kIOHIDOptionsTypeSeizeDevice : kIOHIDOptionsTypeNone)
        let result = IOHIDDeviceOpen(device, options)
        if wantsExclusive { Self.logger.notice("target exclusive device open result=\(result)") }
        guard result == kIOReturnSuccess else {
            onStatus("无法打开目标遥控器（\(result)）", false)
            return
        }
        currentDevice = device
        voiceTarget = true
        if !wantsExclusive {
            IOHIDDeviceRegisterInputReportWithTimeStampCallback(
                device, reportBuffer, 4096, hidReport, Unmanaged.passUnretained(self).toOpaque()
            )
        }
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        onVoiceConnection(true)
        publishInputDiagnostics(force: true)
        logDescriptor(for: device)
        if wantsExclusive {
            keyFilteringReady = true
            onStatus("目标 IOHID 独占打开成功；等待实际报告", true)
            recoverHeldMicrophone(device)
            return
        }
        if !refreshDeviceFilter() {
            let deadline = ProcessInfo.processInfo.systemUptime + 1
            filterTimer?.invalidate()
            filterTimer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                if self.refreshDeviceFilter() || ProcessInfo.processInfo.systemUptime > deadline {
                    timer.invalidate()
                }
            }
        }
    }

    private func recoverHeldMicrophone(_ device: IOHIDDevice) {
        // A wake-up press can precede report subscription. Read only this
        // device's cached input state; never poll the remote or guess a press.
        let matching = [kIOHIDElementUsagePageKey: 7,
                        kIOHIDElementUsageKey: Int(RemoteKey.microphone.rawValue)]
        let elements = IOHIDDeviceCopyMatchingElements(device, matching as CFDictionary, 0) as? [IOHIDElement] ?? []
        let valuePointer = UnsafeMutablePointer<Unmanaged<IOHIDValue>>.allocate(capacity: 1)
        defer { valuePointer.deallocate() }
        for element in elements where IOHIDElementGetReportID(element) == 1
            && IOHIDElementGetType(element) == kIOHIDElementTypeInput_Button {
            let result = IOHIDDeviceGetValueWithOptions(device, element, valuePointer,
                IOHIDDeviceGetValueOptions.withoutUpdate.rawValue)
            guard result == kIOReturnSuccess else { continue }
            let value = valuePointer.pointee.takeUnretainedValue()
            if IOHIDValueGetIntegerValue(value) != 0 {
                Self.logger.notice("target cached microphone is held at exclusive attachment")
                receivedReport([1, 0, 0, RemoteKey.microphone.rawValue, 0, 0, 0, 0, 0],
                               reportID: 1, timestamp: IOHIDValueGetTimeStamp(value))
                return
            }
        }
    }

    private func refreshDeviceFilter() -> Bool {
        if exclusiveReports { return true }
        if wantsExclusive { return currentDevice != nil && keyFilteringReady }
        guard let currentDevice else { return false }
        let ready = deviceFilter.install(for: currentDevice)
        if ready != keyFilteringReady || deviceFilter.status != lastFilterStatus {
            Self.logger.notice("target device mapping ready=\(ready) status=\(self.deviceFilter.status, privacy: .public)")
            lastFilterStatus = deviceFilter.status
        }
        if keyFilteringReady && !ready { releasePressedKeys() }
        keyFilteringReady = ready
        onStatus(deviceFilter.status, ready)
        return ready
    }

    private func logDescriptor(for device: IOHIDDevice) {
        func number(_ key: String) -> Int {
            (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? -1
        }
        let descriptor = (IOHIDDeviceGetProperty(
            device, kIOHIDReportDescriptorKey as CFString
        ) as? Data)?.map { String(format: "%02X", $0) }.joined() ?? "<none>"
        let elements = (IOHIDDeviceCopyMatchingElements(
            device, nil, IOOptionBits(kIOHIDOptionsTypeNone)
        ) as? [IOHIDElement]) ?? []
        let reports = Set(elements.map {
            "\(IOHIDElementGetType($0).rawValue):\(IOHIDElementGetReportID($0))"
        }).sorted().joined(separator: ",")
        Self.logger.notice(
            "matched descriptor=\(descriptor, privacy: .public) maxInput=\(number(kIOHIDMaxInputReportSizeKey), privacy: .public) maxOutput=\(number(kIOHIDMaxOutputReportSizeKey), privacy: .public) maxFeature=\(number(kIOHIDMaxFeatureReportSizeKey), privacy: .public) elementTypeReports=\(reports, privacy: .public)"
        )
    }

    fileprivate func removed(_ device: IOHIDDevice) {
        if currentDevice === device {
            if wantsExclusive { Self.logger.notice("target exclusive device disconnected; manager remains armed") }
            IOHIDDeviceRegisterInputReportWithTimeStampCallback(device, reportBuffer, 4096, nil, nil)
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            deviceFilter.restore()
            filterTimer?.invalidate(); filterTimer = nil
            keyFilteringReady = false
            currentDevice = nil
            voiceTarget = false
            onVoiceConnection(false)
            publishInputDiagnostics(force: true)
            releasePressedKeys()
            onStatus("等待 IPRC1000 连接", false)
        }
    }

    private func releasePressedKeys() {
        let held = pressed
        pressed.removeAll()
        for usage in held where usage != 0x0C {
            if let key = RemoteKey(rawValue: usage) { onKeyUp(key) }
        }
    }

    private func publishInputDiagnostics(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastDiagnosticsTime >= 0.5 else { return }
        lastDiagnosticsTime = now
        let connection = currentDevice == nil ? "设备已断开" :
            (voiceTarget ? "设备已连接，语音身份校验通过" : "设备已连接，语音身份校验未通过")
        let ids = reportIDs.sorted().map { String(format: "%02X", $0) }.joined(separator: ", ")
        let error = lastCallbackError.map { " · 最近错误：\($0)" } ?? ""
        onInputDiagnostics("\(connection)\n按键报告 \(keyboardReports) · F7 报告 \(voiceReports) · 回调错误 \(callbackErrors)\n报告编号：\(ids.isEmpty ? "尚无" : ids)\(error)")
    }

    fileprivate func noteCallback(result: IOReturn, type: IOHIDReportType,
                                  sender: UnsafeMutableRawPointer?, reportID: UInt32, length: CFIndex) -> Bool {
        guard let currentDevice else { return false }
        let senderMatches = sender == Unmanaged.passUnretained(currentDevice).toOpaque()
        let isNewID = reportIDs.insert(reportID).inserted
        if reportID == 1 { keyboardReports += 1 }
        if reportID == 0xF7 { voiceReports += 1 }
        let valid = senderMatches && result == kIOReturnSuccess && type == kIOHIDReportTypeInput
            && length > 0 && length <= 4096
        if !valid {
            callbackErrors += 1
            lastCallbackError = String(format: "0x%08X", UInt32(bitPattern: result))
                + " id=\(reportID) length=\(length) type=\(type.rawValue) senderMatches=\(senderMatches)"
        }
        if isNewID || !valid {
            Self.logger.notice("input callback result=\(result, privacy: .public) type=\(type.rawValue, privacy: .public) id=\(reportID, privacy: .public) length=\(length, privacy: .public) voiceIdentity=\(self.voiceTarget, privacy: .public)")
        }
        publishInputDiagnostics(force: isNewID || !valid)
        return valid
    }

    func exclusiveConnectionChanged(_ ready: Bool) {
        releasePressedKeys()
        exclusiveReports = ready
        if ready { startRepeatTimer() }
        else { repeatTimer?.invalidate(); repeatTimer = nil }
        keyFilteringReady = ready
        onStatus(ready ? "目标遥控器由单客户端独占接收" : "目标遥控器独占接管未就绪", ready)
    }

    func receiveExclusiveKeyboard(_ report: [UInt8]) {
        guard exclusiveReports, report.count == 9, report.first == 1 else { return }
        receivedReport(report, reportID: 1, timestamp: 0)
    }

    func prepareDeviceFilter() -> Bool { refreshDeviceFilter() }
    func maintainDeviceFilter() -> Bool { refreshDeviceFilter() }

    fileprivate func receivedReport(_ report: [UInt8], reportID: Int, timestamp: UInt64) {
        if reportID == 0xF7 {
            if voiceTarget { onVoiceReport(report, reportID) }
            else { Self.logger.error("F7 callback rejected: voice identity not established") }
            return
        }
        guard HIDReportParser.isValidKeyboardReport(report, reportID: reportID),
              keyFilteringReady || refreshDeviceFilter() else { return }
        onKeyboardReport(report)
        let next = HIDReportParser.rawUsages(from: report, reportID: reportID)
        let removed = pressed.subtracting(next)
        let added = next.subtracting(pressed)
        let bytes = report.map { String(format: "%02X", $0) }.joined(separator: " ")
        Self.logger.notice(
            "report id=\(reportID, privacy: .public) timestamp=\(timestamp, privacy: .public) bytes=\(bytes, privacy: .public)"
        )
        for usage in removed {
            if usage != 0x0C, let key = RemoteKey(rawValue: usage) { onKeyUp(key) }
        }
        for usage in added {
            if usage != 0x0C, let key = RemoteKey(rawValue: usage) { onKey(key) }
        }
        if !added.isEmpty { repeatAfter = ProcessInfo.processInfo.systemUptime + 0.5 }
        pressed = next
    }

    static func repeatingKey(for keyCode: CGKeyCode, pressed: Set<UInt8>) -> RemoteKey? {
        guard let usage = pressed.first(where: {
            $0 != 0x0C && RemoteKeyCode.virtualKeyCode(for: $0) == keyCode
        }) else { return nil }
        return RemoteKey(rawValue: usage)
    }
}
