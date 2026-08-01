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

    func read() -> Float {
        lock.lock()
        defer { lock.unlock() }
        guard available > 0 else { return 0 }
        let value = storage[readIndex]
        readIndex = (readIndex + 1) % storage.count
        available -= 1
        return value
    }
}

final class BlackHoleOutput: @unchecked Sendable {
    private let ring = FloatRingBuffer(capacity: 48000 * 5)
    private var device: AudioDeviceID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private(set) var sampleRate = 48000.0

    deinit { stop() }

    func start() -> (ok: Bool, message: String) {
        guard let found = Self.findDevice(named: "BlackHole 2ch") else {
            return (false, "未找到 BlackHole 2ch")
        }
        device = found
        sampleRate = Self.nominalSampleRate(of: found) ?? 48000
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

    func enqueue16kMono(_ samples: [Int16]) {
        guard samples.count > 1 else { return }
        let ratio = sampleRate / 16000.0
        let outputCount = Int(Double(samples.count) * ratio)
        var resampled = [Float]()
        resampled.reserveCapacity(outputCount)
        for index in 0..<outputCount {
            let position = Double(index) / ratio
            let low = min(Int(position), samples.count - 1)
            let high = min(low + 1, samples.count - 1)
            let fraction = Float(position - Double(low))
            let a = Float(samples[low]) / Float(Int16.max)
            let b = Float(samples[high]) / Float(Int16.max)
            resampled.append(a + (b - a) * fraction)
        }
        ring.write(resampled)
    }

    fileprivate func render(_ outputData: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(outputData)
        guard !buffers.isEmpty else { return }
        let frames = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
            / max(Int(buffers[0].mNumberChannels), 1)
        var mono = [Float](repeating: 0, count: frames)
        for index in mono.indices { mono[index] = ring.read() }
        for bufferIndex in buffers.indices {
            guard let data = buffers[bufferIndex].mData else { continue }
            let channels = max(Int(buffers[bufferIndex].mNumberChannels), 1)
            let pointer = data.bindMemory(to: Float.self, capacity: frames * channels)
            for frame in 0..<frames {
                for channel in 0..<channels { pointer[frame * channels + channel] = mono[frame] }
            }
        }
    }

    private static func findDevice(named name: String) -> AudioDeviceID? {
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
