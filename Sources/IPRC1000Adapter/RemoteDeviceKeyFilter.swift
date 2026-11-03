import Foundation
import IOKit.hid
import IOKit.hidsystem
import IOKit

/// Changes only the uniquely paired remote's service properties. No event tap.
final class RemoteDeviceKeyFilter {
    private let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
    private var service: IOHIDServiceClient?
    private var boundDevice: IOHIDDevice?
    private var previous: CFTypeRef?
    private let property = "UserKeyMapping" as CFString
    private(set) var status = "等待遥控器键盘服务"

    static let mappings: [[String: UInt64]] = {
        (Set(RemoteKey.allCases.map(\.rawValue)).union([0x0C])).sorted().map {
            ["HIDKeyboardModifierMappingSrc": (UInt64(7) << 32) | UInt64($0),
             "HIDKeyboardModifierMappingDst": 0]
        }
    }()

    static func matchesService(vendorID: Int?, productID: Int?, transport: String?,
                               deviceID: UInt64?, expectedDeviceID: UInt64) -> Bool {
        return vendorID == TargetRemote.vendorID && productID == TargetRemote.productID
            && transport == "Bluetooth" && expectedDeviceID != 0 && deviceID == expectedDeviceID
    }

    func install(for device: IOHIDDevice) -> Bool {
        if boundDevice === device, let service,
           let current = IOHIDServiceClientCopyProperty(service, property) as? NSArray,
           current.isEqual(Self.mappings as NSArray) { return true }
        guard TargetRemote.matchesVoice(device),
              let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] else {
            status = "目标身份或键盘服务尚未就绪"
            return false
        }
        var deviceID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &deviceID) == KERN_SUCCESS else {
            status = "无法取得已校验遥控器的设备实例"
            return false
        }
        let targets = services.filter { candidate in
            func value(_ key: String) -> CFTypeRef? {
                IOHIDServiceClientCopyProperty(candidate, key as CFString)
            }
            guard (value(kIOHIDVendorIDKey) as? NSNumber)?.intValue == TargetRemote.vendorID,
                  (value(kIOHIDProductIDKey) as? NSNumber)?.intValue == TargetRemote.productID else { return false }
            return Self.matchesService(
                vendorID: (value(kIOHIDVendorIDKey) as? NSNumber)?.intValue,
                productID: (value(kIOHIDProductIDKey) as? NSNumber)?.intValue,
                transport: value(kIOHIDTransportKey) as? String,
                deviceID: Self.hasAncestor(candidate, deviceID: deviceID) ? deviceID : nil,
                expectedDeviceID: deviceID)
                && IOHIDServiceClientConformsTo(candidate, 1, 6) != 0
        }
        guard targets.count == 1, let target = targets.first else {
            status = "需要唯一匹配遥控器地址的键盘服务（当前 \(targets.count) 个）"
            return false
        }
        let mapping = Self.mappings as NSArray
        if let service,
           CFEqual(IOHIDServiceClientGetRegistryID(service), IOHIDServiceClientGetRegistryID(target)),
           let current = IOHIDServiceClientCopyProperty(service, property) as? NSArray,
           current.isEqual(mapping) { return true }
        restore()
        service = target
        boundDevice = device
        previous = IOHIDServiceClientCopyProperty(target, property)
        guard IOHIDServiceClientSetProperty(target, property, mapping),
              let current = IOHIDServiceClientCopyProperty(target, property) as? NSArray,
              current.isEqual(mapping) else {
            status = "遥控器定向按键映射未通过写入回读检查"
            restore()
            return false
        }
        status = "遥控器系统按键映射已回读；原始 HID 隔离尚未验证"
        return true
    }

    private static func hasAncestor(_ service: IOHIDServiceClient, deviceID: UInt64) -> Bool {
        guard let number = IOHIDServiceClientGetRegistryID(service) as? NSNumber else { return false }
        var entry = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(number.uint64Value))
        while entry != 0 {
            var currentID: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(entry, &currentID) == KERN_SUCCESS, currentID == deviceID {
                IOObjectRelease(entry)
                return true
            }
            var parent: io_registry_entry_t = 0
            let result = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
            IOObjectRelease(entry)
            if result != KERN_SUCCESS { return false }
            entry = parent
        }
        return false
    }

    func restore() {
        if let service,
           let current = IOHIDServiceClientCopyProperty(service, property) as? NSArray,
           current.isEqual(Self.mappings as NSArray) {
            _ = IOHIDServiceClientSetProperty(service, property, previous ?? ([] as NSArray))
        }
        service = nil
        boundDevice = nil
        previous = nil
    }

    deinit { restore() }
}
