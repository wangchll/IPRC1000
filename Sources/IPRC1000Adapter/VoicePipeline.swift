import CRemoteSupport
import Foundation

enum VoicePacketAssembler {
    private static let sequences: Set<UInt8> = [0x08, 0x38, 0xC8, 0xF8]

    struct State {
        fileprivate var bytes: [UInt8] = []
        fileprivate var packetCount = 0
    }

    /// The remote splits one 57-byte mSBC frame across three 20-byte BLE packets.
    /// Packet one starts with the two-byte H2 header; byte 59 is padding.
    static func append(_ packet: [UInt8], to state: inout State) -> [UInt8]? {
        guard packet.count == 20 else {
            state = State()
            return nil
        }
        let isStart = packet.count >= 3 && packet[0] == 0x01
            && sequences.contains(packet[1]) && packet[2] == 0xAD
        if isStart {
            state.bytes = packet
            state.packetCount = 1
            return nil
        }
        guard state.packetCount > 0 else { return nil }
        state.bytes.append(contentsOf: packet)
        state.packetCount += 1
        guard state.packetCount == 3 else { return nil }
        defer { state = State() }
        guard state.bytes.count == 60 else { return nil }
        return Array(state.bytes[2..<59])
    }
}

final class MSBCDecoder {
    private let reference: IPRCSBCDecoderRef

    init?() {
        guard let decoder = iprc_sbc_decoder_create() else { return nil }
        reference = decoder
    }

    deinit { iprc_sbc_decoder_destroy(reference) }

    func decode(_ frame: [UInt8]) -> [Int16]? {
        guard frame.count == 57 else { return nil }
        var output = [Int16](repeating: 0, count: 256)
        let count = frame.withUnsafeBytes { input in
            output.withUnsafeMutableBufferPointer { pcm in
                iprc_sbc_decode_msbc(
                    reference,
                    input.bindMemory(to: UInt8.self).baseAddress,
                    frame.count,
                    pcm.baseAddress,
                    pcm.count
                )
            }
        }
        guard count > 0 else { return nil }
        return Array(output.prefix(Int(count)))
    }
}

enum GoogleVoiceADPCM {
    private static let stepTable = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31,
        34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143,
        157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544,
        598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707,
        1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871,
        5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635,
        13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767
    ]
    private static let indexTable = [-1, -1, -1, -1, 2, 4, 6, 8]

    /// Google Voice 0.4/1.0: big-endian sequence, reserved byte, predictor,
    /// step index, then 256 IMA-ADPCM samples packed into 128 bytes.
    static func decode(_ packet: [UInt8]) -> [Int16]? {
        guard packet.count >= 134, packet[2] == 0, packet[5] <= 88 else { return nil }
        var predictor = Int(Int16(bitPattern: UInt16(packet[3]) << 8 | UInt16(packet[4])))
        var index = Int(packet[5])
        var output: [Int16] = []
        output.reserveCapacity(256)

        for byte in packet[6..<134] {
            for code in [Int(byte & 0x0F), Int(byte >> 4)] {
                let step = stepTable[index]
                var difference = step >> 3
                if code & 1 != 0 { difference += step >> 2 }
                if code & 2 != 0 { difference += step >> 1 }
                if code & 4 != 0 { difference += step }
                predictor += code & 8 != 0 ? -difference : difference
                predictor = min(32767, max(-32768, predictor))
                index = min(88, max(0, index + indexTable[code & 7]))
                output.append(Int16(predictor))
            }
        }
        return output
    }
}

/// Observed Classic HID F7 format. IOHID may include or omit the report ID.
struct ClassicVoiceFrame {
    let sequence: UInt16
    let deviceTime: UInt16
    let bufferState: UInt16
    let reserved: UInt16
    let samples: [Int16]

    static func parse(_ bytes: [UInt8], reportID: Int) -> ClassicVoiceFrame? {
        guard reportID == 0xF7 else { return nil }
        let offset: Int
        if bytes.count == 652, bytes.first == 0xF7 { offset = 1 }
        else if bytes.count == 651 { offset = 0 }
        else { return nil }
        func word(_ index: Int) -> UInt16 {
            UInt16(bytes[offset + index]) | UInt16(bytes[offset + index + 1]) << 8
        }
        guard bytes[offset] == 1, word(9) == 320 else { return nil }
        return ClassicVoiceFrame(
            sequence: word(1), deviceTime: word(3), bufferState: word(5), reserved: word(7),
            samples: stride(from: 11, to: 651, by: 2).map { Int16(bitPattern: word($0)) }
        )
    }
}

struct ClassicVoiceStream {
    private var previous: UInt16?
    private var lastArrival: TimeInterval?
    private(set) var missing = 0
    private(set) var discarded = 0
    private(set) var resynchronized = 0

    mutating func reset() { self = Self() }

    // A new press can restart at zero. Large gaps resynchronize instead of building latency.
    mutating func append(_ frame: ClassicVoiceFrame, at now: TimeInterval)
        -> (samples: [Int16], restarted: Bool)? {
        var restarted = previous == nil || now - (lastArrival ?? now) > 0.5
        var silence = 0
        if let previous, !restarted {
            let delta = frame.sequence &- previous
            if delta == 0 { discarded += 1; return nil }
            if frame.sequence == 0, delta != 1 {
                restarted = true
            } else if delta >= 0x8000 {
                discarded += 1
                return nil
            } else if delta > 1 {
                missing += Int(delta) - 1
                if delta <= 4 { silence = (Int(delta) - 1) * 320 }
                else { restarted = true; resynchronized += 1 }
            }
        }
        previous = frame.sequence
        lastArrival = now
        return ([Int16](repeating: 0, count: silence) + frame.samples, restarted)
    }
}

/// Classic audio is passive: no BLE scanning, SDP discovery, or private START/STOP writes.
final class VoiceController: @unchecked Sendable {
    var onStatus: @Sendable (String, Bool) -> Void = { _, _ in }
    var onLevel: @Sendable (Float) -> Void = { _ in }
    var onSamples: @Sendable ([Int16]) -> Void = { _ in }
    var onUtteranceEnd: @Sendable () -> Void = { }
    var directBlackHoleOutput = true
    private let output = BlackHoleOutput()
    private var stream = ClassicVoiceStream()
    private var outputReady = false
    private var outputMessage = ""
    private var lastArrival: TimeInterval?
    private var timer: Timer?
    private var packets = 0
    private var externalAudio = false
    private var startupSamples: [Int16] = []
    private var startupTimer: Timer?

    func prepareExternalAudio() {
        directBlackHoleOutput = true
        startupTimer?.invalidate()
        externalAudio = true
        startupSamples.removeAll(keepingCapacity: true)
        output.resetAudio()
        startupTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.output.enqueue16kMono(self.startupSamples)
            self.startupSamples.removeAll(keepingCapacity: true)
            self.startupTimer = nil
        }
    }

    func cancelExternalAudio() {
        startupTimer?.invalidate()
        startupTimer = nil
        startupSamples.removeAll(keepingCapacity: true)
        externalAudio = false
    }

    deinit { timer?.invalidate() }

    func start() {
        let status = output.start()
        outputReady = status.ok
        outputMessage = status.message
        onStatus(status.ok ? "等待 Classic HID F7 语音报告；按住麦克风键说话" : status.message, false)
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let last = self.lastArrival,
                  ProcessInfo.processInfo.systemUptime - last > 0.5 else { return }
            if self.externalAudio && (self.startupTimer != nil || self.output.queuedDuration > 0) { return }
            self.lastArrival = nil
            self.stream.reset()
            self.output.resetAudio()
            self.onUtteranceEnd()
            self.onLevel(0)
            self.onStatus("语音已停止；等待下一次 F7（已收 \(self.packets) 帧）", false)
        }
    }

    func connectionChanged(_ ready: Bool) {
        stream.reset()
        lastArrival = nil
        output.resetAudio()
        onLevel(0)
        onStatus(ready ? "Classic HID 监听已就绪，等待 F7 语音报告" : "等待唯一配对遥控器的 Classic HID 连接", false)
    }

    func receive(_ report: [UInt8], reportID: Int) {
        guard let frame = ClassicVoiceFrame.parse(report, reportID: reportID) else {
            onStatus("收到 F7，但格式或长度不符（\(report.count) 字节）", false)
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard let chunk = stream.append(frame, at: now) else { return }
        lastArrival = now
        packets += 1
        onSamples(chunk.samples)
        guard outputReady else {
            onStatus("已收到 Classic F7；\(outputMessage)", false)
            return
        }
        if directBlackHoleOutput {
            if chunk.restarted { output.resetAudio() }
            if startupTimer != nil { startupSamples.append(contentsOf: chunk.samples) }
            else { output.enqueue16kMono(chunk.samples) }
        }
        let peak = frame.samples.reduce(0) { max($0, abs(Int($1))) }
        onLevel(Float(peak) / 32768)
        if packets == 1 || chunk.restarted || packets % 50 == 0 {
            onStatus("F7 → BlackHole 2ch · \(packets) 帧 · 缺序号 \(stream.missing) · 丢弃 \(stream.discarded) · 重同步 \(stream.resynchronized)", true)
        }
    }
}
