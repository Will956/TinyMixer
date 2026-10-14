import CoreAudio
import Foundation

/// Mutes an app's own output through a Core Audio process tap and replays that audio,
/// scaled by `gain`, to the output device through a private aggregate device.
final class AppTap {
    let processObjectIDs: [AudioObjectID]
    let outputDeviceUID: String

    private var tapID = AudioObjectID.unknown
    private var aggregateID = AudioObjectID.unknown
    private var ioProcID: AudioDeviceIOProcID?
    // Shared with the realtime IO thread; raw pointers avoid locks and Swift exclusivity checks there.
    private let targetGain = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private let currentGain = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private let queue = DispatchQueue(label: "TinyMixer.AppTap", qos: .userInteractive)

    var gain: Float {
        get { targetGain.pointee }
        set { targetGain.pointee = max(0, min(1, newValue)) }
    }

    init(name: String, processObjectIDs: [AudioObjectID], outputDevice: AudioDeviceID, gain: Float) throws {
        self.processObjectIDs = processObjectIDs
        self.outputDeviceUID = try CA.deviceUID(outputDevice)
        targetGain.pointee = gain
        currentGain.pointee = gain

        do {
            try start(name: name, outputDevice: outputDevice)
        } catch {
            stop()
            throw error
        }
    }

    deinit {
        stop()
        targetGain.deallocate()
        currentGain.deallocate()
    }

    private func start(name: String, outputDevice: AudioDeviceID) throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        description.uuid = UUID()
        description.name = "TinyMixer \(name)"
        description.isPrivate = true
        // Muting only while tapped means the app's sound comes back on its own if TinyMixer stops or crashes.
        description.muteBehavior = .mutedWhenTapped
        try check(AudioHardwareCreateProcessTap(description, &tapID), "Create process tap")

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "TinyMixer \(name)",
            kAudioAggregateDeviceUIDKey: "TinyMixer-\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputDeviceUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "Create aggregate device")

        // The aggregate lists the output device's own input streams (e.g. a headset mic) before the tap's.
        // Those are skipped so the mic is never opened nor mixed into the output.
        let firstTapBuffer = CA.inputStreamCount(outputDevice)
        let target = targetGain
        let current = currentGain
        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { _, input, _, output, _ in
            let start = current.pointee
            let end = target.pointee
            AppTap.render(
                input: UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)),
                firstInputBuffer: firstTapBuffer,
                output: UnsafeMutableAudioBufferListPointer(output),
                gainFrom: start, to: end
            )
            current.pointee = end
        }, "Create IO proc")

        disableInputStreams(count: firstTapBuffer)
        try check(AudioDeviceStart(aggregateID, ioProcID), "Start aggregate device")
    }

    private func stop() {
        if aggregateID != .unknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != .unknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        ioProcID = nil
        aggregateID = .unknown
        tapID = .unknown
    }

    private func disableInputStreams(count: Int) {
        guard count > 0, let ioProcID else { return }
        var address = CA.address(kAudioDevicePropertyIOProcStreamUsage, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(aggregateID, &address, 0, nil, &size) == noErr else { return }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        let usage = raw.bindMemory(to: AudioHardwareIOProcStreamUsage.self, capacity: 1)
        usage.pointee.mIOProc = unsafeBitCast(ioProcID, to: UnsafeMutableRawPointer.self)
        guard AudioObjectGetPropertyData(aggregateID, &address, 0, nil, &size, raw) == noErr else { return }

        let offset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!
        let streamIsOn = (raw + offset).assumingMemoryBound(to: UInt32.self)
        for index in 0..<min(count, Int(usage.pointee.mNumberStreams)) {
            streamIsOn[index] = 0
        }
        AudioObjectSetPropertyData(aggregateID, &address, 0, nil, size, raw)
    }

    /// Realtime IO thread: no allocation, no locks.
    private static func render(
        input: UnsafeMutableAudioBufferListPointer,
        firstInputBuffer: Int,
        output: UnsafeMutableAudioBufferListPointer,
        gainFrom start: Float, to end: Float
    ) {
        var outputChannel = 0
        for buffer in output {
            guard let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let stride = max(Int(buffer.mNumberChannels), 1)
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * stride)

            for channel in 0..<stride {
                defer { outputChannel += 1 }
                guard let source = inputChannel(outputChannel, in: input, from: firstInputBuffer) else {
                    for frame in 0..<frames { samples[frame * stride + channel] = 0 }
                    continue
                }
                let count = min(frames, source.frames)
                // Ramping across the buffer avoids clicks when the slider moves.
                let step = count > 0 ? (end - start) / Float(count) : 0
                var gain = start
                for frame in 0..<count {
                    samples[frame * stride + channel] = source.samples[frame * source.stride] * gain
                    gain += step
                }
                for frame in count..<frames { samples[frame * stride + channel] = 0 }
            }
        }
    }

    private static func inputChannel(
        _ wanted: Int,
        in input: UnsafeMutableAudioBufferListPointer,
        from firstBuffer: Int
    ) -> (samples: UnsafePointer<Float>, stride: Int, frames: Int)? {
        var channel = 0
        for index in firstBuffer..<max(firstBuffer, input.count) {
            let buffer = input[index]
            let channels = Int(buffer.mNumberChannels)
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self), channels > 0 else { continue }
            if wanted < channel + channels {
                let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
                return (UnsafePointer(data + (wanted - channel)), channels, frames)
            }
            channel += channels
        }
        return nil
    }
}
