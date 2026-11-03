import CoreAudio
import Foundation

private func blackHoleIOProc(
    _ device: AudioObjectID,
    _ now: UnsafePointer<AudioTimeStamp>,
    _ inputData: UnsafePointer<AudioBufferList>,
    _ inputTime: UnsafePointer<AudioTimeStamp>,
    _ outputData: UnsafeMutablePointer<AudioBufferList>,
    _ outputTime: UnsafePointer<AudioTimeStamp>,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData else { return noErr }
    Unmanaged<BlackHoleOutput>.fromOpaque(clientData).takeUnretainedValue().render(outputData)
    return noErr
}

final class FloatRingBuffer: @unchecked Sendable {
    private var storage: [Float]
    private var readIndex = 0
    private var writeIndex = 0
    private var available = 0
    private let lock = NSLock()

    init(capacity: Int) { storage = [Float](repeating: 0, count: capacity) }

    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return available
    }

    func write(_ values: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        for value in values {
            if available == storage.count {
                readIndex = (readIndex + 1) % storage.count
                available -= 1
            }
            storage[writeIndex] = value
            writeIndex = (writeIndex + 1) % storage.count
            available += 1
        }
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        readIndex = 0
        writeIndex = 0
        available = 0
    }

    /// Render never waits for the producer and allocates no scratch storage.
    func render(_ outputData: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(outputData)
        for buffer in buffers {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        guard lock.try() else { return }
        defer { lock.unlock() }
        let frames = buffers.reduce(Int.max) { min($0, Int($1.mDataByteSize) / (4 * max(1, Int($1.mNumberChannels)))) }
        guard !buffers.isEmpty else { return }
        for frame in 0..<frames {
            let value: Float
            if available > 0 {
                value = storage[readIndex]
                readIndex = (readIndex + 1) % storage.count
                available -= 1
            } else { value = 0 }
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let channels = Int(buffer.mNumberChannels)
                let pointer = data.assumingMemoryBound(to: Float.self)
                for channel in 0..<channels { pointer[frame * channels + channel] = value }
            }
        }
    }
}

/// Linear interpolation retains its fractional position and last sample across reports.
struct VoiceResampler {
    private var last: Float?
    private var inputCount = 0
    private var outputCount = 0

    mutating func reset() { self = Self() }

    mutating func process(_ samples: [Int16], sampleRate: Double) -> [Float] {
        guard !samples.isEmpty, sampleRate > 0 else { return [] }
        var input = samples.map { Float($0) / 32768 }
        let startIndex = inputCount - (last == nil ? 0 : 1)
        if let last { input.insert(last, at: 0) }
        inputCount += samples.count
        var output: [Float] = []
        output.reserveCapacity(Int(Double(samples.count) * sampleRate / 16000) + 1)
        while Double(outputCount) * 16000 < Double(inputCount - 1) * sampleRate {
            let position = (Double(outputCount) * 16000 - Double(startIndex) * sampleRate) / sampleRate
            let low = Int(position)
            let fraction = Float(position - Double(low))
            output.append(input[low] + (input[low + 1] - input[low]) * fraction)
            outputCount += 1
        }
        last = input.last
        return output
    }
}

final class BlackHoleOutput: @unchecked Sendable {
    private var ring = FloatRingBuffer(capacity: 9600)
    private var resampler = VoiceResampler()
    private var device: AudioDeviceID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private(set) var sampleRate = 48000.0

    deinit { stop() }

    func start() -> (ok: Bool, message: String) {
        guard let found = Self.findDevice(named: "BlackHole 2ch") else {
            return (false, "未找到 BlackHole 2ch")
        }
        device = found
        guard let rate = Self.nominalSampleRate(of: found), rate.isFinite,
              rate >= 16000, rate <= 192000, Self.hasFloatOutput(found) else {
            return (false, "BlackHole 输出需为 16–192 kHz、32-bit Float PCM")
        }
        sampleRate = rate
        ring = FloatRingBuffer(capacity: Int(rate * 0.7))
        resampler.reset()
        var proc: AudioDeviceIOProcID?
        let created = AudioDeviceCreateIOProcID(
            found, blackHoleIOProc, Unmanaged.passUnretained(self).toOpaque(), &proc
        )
        guard created == noErr, let proc else {
            return (false, "无法打开 BlackHole 2ch 输出（\(created)）")
        }
        ioProcID = proc
        let started = AudioDeviceStart(found, proc)
        guard started == noErr else {
            AudioDeviceDestroyIOProcID(found, proc)
            ioProcID = nil
            return (false, "无法启动 BlackHole 2ch（\(started)）")
        }
        return (true, "BlackHole 2ch 已就绪")
    }

    func stop() {
        guard device != 0, let ioProcID else { return }
        AudioDeviceStop(device, ioProcID)
        AudioDeviceDestroyIOProcID(device, ioProcID)
        self.ioProcID = nil
    }

    func resetAudio() {
        ring.reset()
        resampler.reset()
    }

    func enqueue16kMono(_ samples: [Int16]) {
        ring.write(resampler.process(samples, sampleRate: sampleRate))
    }

    var queuedDuration: TimeInterval { Double(ring.pendingCount) / sampleRate }

    fileprivate func render(_ outputData: UnsafeMutablePointer<AudioBufferList>) {
        ring.render(outputData)
    }

    private static func hasFloatOutput(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &format) == noErr else { return false }
        let channels = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
            ? 1 : format.mChannelsPerFrame
        return format.mFormatID == kAudioFormatLinearPCM
            && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0
            && format.mBitsPerChannel == 32 && format.mChannelsPerFrame > 0
            && format.mBytesPerFrame == 4 * channels
    }

    static func findDevice(named name: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address,
                                             0, nil, &size) == noErr else { return nil }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                         &size, &devices) == noErr else { return nil }
        return devices.first { deviceName(of: $0) == name }
    }

    private static func deviceName(of device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let value = UnsafeMutablePointer<CFString?>.allocate(capacity: 1)
        value.initialize(to: nil)
        defer {
            value.deinitialize(count: 1)
            value.deallocate()
        }
        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, value) == noErr,
              let name = value.pointee else { return nil }
        return name as String
    }

    private static func nominalSampleRate(of device: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate = 0.0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr else { return nil }
        return rate
    }
}
