import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

/// The microphone with Apple's voice processing, which cancels what the default
/// output device is playing. In an online meeting through speakers, this keeps the
/// other participants out of the "You" track.
///
/// Requires macOS 14 for the ducking configuration: without it, voice processing
/// lowers other apps' audio, including the meeting.
@available(macOS 14.0, *)
final class VoiceProcessingMicInput: MicInput {
    var onBuffer: ((AVAudioPCMBuffer, Double) -> Void)?
    var onInterruption: ((String) -> Void)?
    private let queue: DispatchQueue
    private let engine = AVAudioEngine()
    private var observer: NSObjectProtocol?
    private var reportedUndecodable = false

    init(queue: DispatchQueue) { self.queue = queue }
    deinit { stop() }

    func start(device: AVCaptureDevice, explicitlySelected: Bool) throws {
        do { try startEngine(device: device, explicitlySelected: explicitlySelected) }
        catch { stop(); throw error }
    }
    private func startEngine(device: AVCaptureDevice, explicitlySelected: Bool) throws {
        let input = engine.inputNode
        // Voice processing first: enabling it reconfigures the unit, so the device is
        // chosen afterwards and read back to confirm.
        try input.setVoiceProcessingEnabled(true)
        input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
        if explicitlySelected { try select(device, on: input) }

        let format = input.outputFormat(forBus: 0)
        guard format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
              format.sampleRate > 0, format.channelCount > 0 else {
            throw RuntimeError("Voice processing returned an unsupported microphone format.")
        }
        // Never tear the engine down inside this notification; only report on the queue.
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                          object: engine, queue: nil) { [weak self] _ in
            self?.queue.async { self?.onInterruption?("Microphone capture was interrupted. The saved audio is preserved.") }
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, time in
            self?.deliver(buffer, at: time)
        }
        engine.prepare()
        try engine.start()
    }

    /// Runs on the engine's tap thread. Copies before handing over: the engine reuses `buffer`.
    private func deliver(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        guard time.isHostTimeValid, let voice = Self.firstChannel(of: buffer) else {
            queue.async { [weak self] in
                guard let self, !self.reportedUndecodable else { return }
                self.reportedUndecodable = true
                self.onInterruption?("Microphone audio could not be decoded.")
            }
            return
        }
        let seconds = AVAudioTime.seconds(forHostTime: time.hostTime)
        queue.async { [weak self] in self?.onBuffer?(voice, seconds) }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? engine.inputNode.setVoiceProcessingEnabled(false)
    }

    private func select(_ device: AVCaptureDevice, on input: AVAudioInputNode) throws {
        let unavailable = RuntimeError("The selected microphone does not support echo cancellation.")
        guard let unit = input.audioUnit, var id = CoreAudioDevices.deviceID(forUID: device.uniqueID) else { throw unavailable }
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, size) == noErr
        else { throw unavailable }
        var current = AudioDeviceID(kAudioObjectUnknown)
        var currentSize = size
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &current, &currentSize) == noErr,
              current == id else { throw unavailable }
    }

    /// Voice processing may report several channels; the processed voice is channel 0.
    /// Copied as-is at the native rate (never downmixed); `PCMTrackWriter` resamples.
    static func firstChannel(of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let source = buffer.floatChannelData?[0], buffer.frameLength > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate,
                                         channels: 1, interleaved: false),
              let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
              let destination = copy.floatChannelData?[0] else { return nil }
        destination.update(from: source, count: Int(buffer.frameLength))
        copy.frameLength = buffer.frameLength
        return copy
    }
}

/// Small Core Audio lookups used for device selection and session diagnostics.
enum CoreAudioDevices {
    static func defaultInputUID() -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              hasInputChannels(id) else { return nil }
        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    static func hasInputChannels(_ id: AudioDeviceID) -> Bool {
        guard id != kAudioObjectUnknown else { return false }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &alive) == noErr, alive != 0 else { return false }
        address.mSelector = kAudioDevicePropertyStreamConfiguration
        address.mScope = kAudioDevicePropertyScopeInput
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioBufferList>.size else { return false }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, storage) == noErr else { return false }
        return UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
            .contains { $0.mNumberChannels > 0 }
    }

    static func isMicrophone(uid: String) -> Bool {
        deviceID(forUID: uid).map(hasInputChannels) ?? false
    }

    /// `AVCaptureDevice.uniqueID` on macOS is the Core Audio device UID.
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), uidPointer, &size, &id)
        }
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    /// Name of the default output: the reference voice processing cancels against.
    static func defaultOutputName() -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        address.mSelector = kAudioObjectPropertyName
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }
}
