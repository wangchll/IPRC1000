import Foundation
import IOKit.hid
import os

enum TargetRemote {
    static let vendorID = 0x0A5C
    static let productID = 0x8502
    static let productName = "IPRC1000"

    static func matches(vendorID: Int?, productID: Int?, productName: String?) -> Bool {
        vendorID == self.vendorID
            && productID == self.productID
            && productName == self.productName
    }

    static func matches(_ device: IOHIDDevice) -> Bool {
        matches(
            vendorID: numberProperty(device, key: kIOHIDVendorIDKey),
            productID: numberProperty(device, key: kIOHIDProductIDKey),
            productName: stringProperty(device, key: kIOHIDProductKey)
        )
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
    Unmanaged<HIDController>.fromOpaque(context).takeUnretainedValue()
        .receivedReport(
            Array(UnsafeBufferPointer(start: report, count: reportLength)),
            reportID: Int(reportID), timestamp: timestamp
        )
}

final class HIDController: @unchecked Sendable {
    private static let logger = Logger(subsystem: "local.iprc1000.adapter", category: "HIDReport")
    var onStatus: @Sendable (String, Bool) -> Void = { _, _ in }
    var onKey: @Sendable (RemoteKey) -> Void = { _ in }

    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private let eventFilter = RemoteEventFilter()
    private var pressed: Set<UInt8> = []
    private var currentDevice: IOHIDDevice?

    deinit {
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func start() {
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: TargetRemote.vendorID,
            kIOHIDProductIDKey as String: TargetRemote.productID,
            kIOHIDProductKey as String: TargetRemote.productName
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, hidMatched, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, hidRemoved, context)
        IOHIDManagerRegisterInputReportWithTimeStampCallback(manager, hidReport, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        guard eventFilter.start() else {
            onStatus("无法启动按键过滤；请允许辅助功能与输入监控", false)
            return
        }
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess {
            onStatus("无法启动 HID 管理器（\(result)）", false)
        } else {
            onStatus("等待 IPRC1000（0A5C:8502）", false)
        }
    }

    fileprivate func matched(_ device: IOHIDDevice) {
        guard TargetRemote.matches(device), currentDevice == nil else { return }
        currentDevice = device
        logDescriptor(for: device)
        onStatus("IPRC1000 已连接，设备级过滤与按键适配已启用", true)
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
            currentDevice = nil
            pressed = []
            onStatus("等待 IPRC1000 连接", false)
        }
    }

    fileprivate func receivedReport(_ report: [UInt8], reportID: Int, timestamp: UInt64) {
        let next = HIDReportParser.rawUsages(from: report, reportID: reportID)
        let removed = pressed.subtracting(next)
        let added = next.subtracting(pressed)
        let bytes = report.map { String(format: "%02X", $0) }.joined(separator: " ")
        Self.logger.notice(
            "report id=\(reportID, privacy: .public) timestamp=\(timestamp, privacy: .public) bytes=\(bytes, privacy: .public)"
        )
        for usage in removed {
            eventFilter.note(usage: usage, isDown: false, hidTimestamp: timestamp)
        }
        for usage in added {
            eventFilter.note(usage: usage, isDown: true, hidTimestamp: timestamp)
            if usage != 0x0C, let key = RemoteKey(rawValue: usage) { onKey(key) }
        }
        pressed = next
    }
}
