import Foundation
import AVFoundation
import CoreMedia

public struct MicDevice: Sendable, Identifiable, Hashable {
    public let uniqueID: String
    public let name: String
    public var id: String { uniqueID }
}

/// Which microphone path a capture used, recorded in `capture.json` for debugging.
public struct MicProcessing: Sendable {
    public enum Mode: String, Sendable { case voice, raw }
    public let mode: Mode
    /// Why the raw path was used although voice processing was requested.
    public let note: String?
}

@available(macOS 13.0, *)
public final class MicCapture: @unchecked Sendable {
    public static func available() -> [MicDevice] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInMicrophone]
        if #available(macOS 14.0, *) { types.append(.external) }
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .audio, position: .unspecified)
            .devices.filter { CoreAudioDevices.isMicrophone(uid: $0.uniqueID) }
            .map { MicDevice(uniqueID: $0.uniqueID, name: $0.localizedName) }
    }
    private let queue = DispatchQueue(label: "transcribe.mic.capture")
    private let lock = NSLock()
    private let echoCancellation: Bool
    private var stopped = false
    private var input: MicInput?
    private var processing: MicProcessing?
    private var liveness = AudioLiveness()
    private var livenessReported = false
    private var watchdog: DispatchSourceTimer?
    private let startup = MicrophoneStartup()
    private let recorder: PCMTrackWriter
    public var onLog: (@Sendable (String) -> Void)?
    public var onLevel: (@Sendable (Double) -> Void)?
    public var onHealth: (@Sendable (CaptureHealth) -> Void)?
    public var onPart: (@Sendable (AudioSpan) -> Void)?
    public var onAudioFrame: (@Sendable (CapturedAudioFrame) -> Void)?
    /// `echoCancellation` asks for voice processing (online meetings). The raw
    /// microphone is used when it is unavailable, so recording never depends on it.
    public init(outputURL: URL, epoch: Double = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())),
                echoCancellation: Bool = false) {
        recorder = PCMTrackWriter(directory: outputURL.deletingLastPathComponent(), source: .mic, epoch: epoch)
        self.echoCancellation = echoCancellation
        recorder.onLevel = { [weak self] in self?.onLevel?($0) }
        recorder.onHealth = { [weak self] in self?.onHealth?($0) }
        recorder.onPart = { [weak self] in self?.onPart?($0) }
        recorder.onAudioFrame = { [weak self] in self?.onAudioFrame?($0) }
    }
    deinit { watchdog?.cancel() }
    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    public var capturedSpans: [AudioSpan] { queue.sync { recorder.spans } }
    public var closedSpans: [AudioSpan] { queue.sync { recorder.closedSpans() } }
    /// Set once the microphone has started.
    public var microphoneProcessing: MicProcessing? { queue.sync { processing } }

    @discardableResult
    public func start(uniqueID: String?) throws -> String {
        guard !isStopped else { throw CancellationError() }
        // Resolve the device before choosing a path, so an unavailable microphone
        // fails exactly as before and is never hidden by a fallback.
        let device: AVCaptureDevice
        if let uniqueID {
            guard CoreAudioDevices.isMicrophone(uid: uniqueID),
                  let chosen = AVCaptureDevice(uniqueID: uniqueID) else {
                throw MicrophoneCaptureError(message: "The selected microphone is disconnected or unavailable. Connect it or choose another microphone.")
            }
            device = chosen
        } else {
            guard let uid = CoreAudioDevices.defaultInputUID(),
                  let chosen = AVCaptureDevice(uniqueID: uid) else {
                throw MicrophoneCaptureError(message: "No microphone is connected. Connect a microphone and try again.")
            }
            device = chosen
        }
        onHealth?(CaptureHealth(source: .mic, state: .starting))
        queue.sync { liveness.start(at: captureHostSeconds()) }
        let (started, processing) = try startInput(device, explicitlySelected: uniqueID != nil)
        try queue.sync {
            guard !isStopped else { started.stop(); throw CancellationError() }
            input = started; self.processing = processing
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in
                guard let self, !self.isStopped else { return }
                self.checkLiveness()
            }
            watchdog = timer; timer.resume()
        }
        do { try startup.wait() }
        catch {
            queue.sync { started.stop(); _ = recorder.stop() }
            throw error
        }
        return device.localizedName
    }
    /// Voice processing when requested and possible, otherwise the raw microphone.
    private func startInput(_ device: AVCaptureDevice, explicitlySelected: Bool) throws -> (MicInput, MicProcessing) {
        var note: String?
        if echoCancellation {
            if ProcessInfo.processInfo.environment["TRANSCRIBE_MIC_PROCESSING"] == "raw" {
                note = "Forced by TRANSCRIBE_MIC_PROCESSING=raw."
            } else if #available(macOS 14.0, *) {
                let voice = VoiceProcessingMicInput(queue: queue)
                connect(voice)
                do {
                    try voice.start(device: device, explicitlySelected: explicitlySelected)
                    return (voice, MicProcessing(mode: .voice, note: nil))
                } catch {
                    // The input has already torn itself down.
                    note = "Echo cancellation unavailable: \(error)"
                    onLog?("Echo cancellation unavailable; recording the raw microphone.")
                }
            } else {
                note = "Echo cancellation needs macOS 14."
            }
            guard !isStopped else { throw CancellationError() }
        }
        let raw = CaptureSessionMicInput(queue: queue)
        connect(raw)
        try raw.start(device: device, explicitlySelected: explicitlySelected)
        return (raw, MicProcessing(mode: .raw, note: note))
    }
    private func connect(_ input: MicInput) {
        input.onBuffer = { [weak self] buffer, time in self?.receive(buffer, at: time) }
        input.onInterruption = { [weak self] message in
            guard let self, !self.isStopped else { return }
            self.reportInterruption(message)
        }
    }
    /// On the capture queue.
    private func receive(_ buffer: AVAudioPCMBuffer, at time: Double) {
        guard !isStopped else { return }
        liveness.received(at: captureHostSeconds())
        do {
            try recorder.append(buffer, pts: time)
            if recorder.spans.contains(where: { $0.duration > 0 }) { startup.recordedAudio() }
        }
        catch {
            startup.failed("Microphone audio could not be saved.")
            onHealth?(CaptureHealth(source: .mic, state: .interrupted, message: "Microphone audio could not be saved."))
            onLog?("Microphone audio could not be saved.")
        }
    }
    private func reportInterruption(_ message: String) {
        let message = recorder.spans.contains(where: { $0.duration > 0 }) ? message
            : "No microphone audio was captured. Connect a microphone and try again."
        startup.failed(message)
        guard !livenessReported else { return }
        livenessReported = true
        onHealth?(CaptureHealth(source: .mic, state: .interrupted, message: message))
        onLevel?(0)
    }
    private func checkLiveness(at time: Double = captureHostSeconds()) {
        guard let failure = liveness.failure(at: time) else { return }
        reportInterruption(failure == .noBuffers
            ? "No microphone audio arrived. Check the microphone and its permission."
            : "Microphone audio stopped arriving. The saved audio is preserved.")
    }
    public func stop() async {
        let stopRequestedAt = captureHostSeconds()
        lock.withLock { stopped = true }
        await withCheckedContinuation { continuation in
            queue.async {
                self.checkLiveness(at: stopRequestedAt)
                self.watchdog?.cancel(); self.watchdog = nil
                self.input?.stop()
                _ = self.recorder.stop()
                self.onLevel?(0)
                continuation.resume()
            }
        }
    }
}
