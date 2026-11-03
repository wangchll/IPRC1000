import Foundation

/// Subscription and actual audio availability are different states. A connection
/// change invalidates the evidence from the previous physical connection.
struct DeviceVoiceReadiness {
    private(set) var deviceID: UInt64?
    private(set) var audioReceived = false

    mutating func connected(_ id: UInt64) {
        deviceID = id
        audioReceived = false
    }

    @discardableResult
    mutating func received(_ report: [UInt8], reportID: Int, from id: UInt64) -> Bool {
        guard deviceID == id, ClassicVoiceFrame.parse(report, reportID: reportID) != nil else { return false }
        audioReceived = true
        return true
    }

    mutating func disconnected(_ id: UInt64) {
        guard deviceID == id else { return }
        deviceID = nil
        audioReceived = false
    }
}

@MainActor
final class DeviceVoiceInput {
    private let capture = HIDController()
    private let expectedAddress: String?
    private(set) var isRunning = false
    private var connection = 0 as UInt64
    private var readiness = DeviceVoiceReadiness()
    var onKeyboard: ([UInt8]) -> Void = { _ in }
    var onIsolation: (Bool) -> Void = { _ in }
    var onReport: ([UInt8], Bool) -> Void = { _, _ in }
    var onStatus: (String, Bool) -> Void = { _, _ in }
    var onAudioAvailable: (Bool) -> Void = { _ in }

    init(expectedAddress: String? = nil) {
        self.expectedAddress = expectedAddress
        capture.onStatus = { [weak self] message, ready in
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                self.onIsolation(ready)
                self.onStatus(message, true)
            }
        }
        capture.onVoiceConnection = { [weak self] ready in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.connection &+= 1
                self.readiness = DeviceVoiceReadiness()
                if ready { self.readiness.connected(self.connection) }
                self.onAudioAvailable(false)
                if !ready { self.onIsolation(false) }
            }
        }
        capture.onKeyboardReport = { [weak self] report in
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                self.onKeyboard(report)
            }
        }
        capture.onVoiceReport = { [weak self] report, id in
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                let first = !self.readiness.audioReceived
                guard self.readiness.received(report, reportID: id, from: self.connection) else { return }
                if first { self.onAudioAvailable(true) }
                self.onReport(report, first)
            }
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        capture.startExclusive(address: expectedAddress)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        capture.stop()
        readiness = DeviceVoiceReadiness()
        onAudioAvailable(false)
        onIsolation(false)
        onStatus("单设备独占监听已停止", false)
    }
}
