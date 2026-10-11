import Foundation
import AVFoundation
import CoreMedia

public struct MicDevice: Sendable, Identifiable, Hashable {
    public let uniqueID: String
    public let name: String
    public var id: String { uniqueID }
}

@available(macOS 13.0, *)
public final class MicCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    public static func available() -> [MicDevice] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInMicrophone]
        if #available(macOS 14.0, *) { types.append(.external) }
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .audio, position: .unspecified)
            .devices.map { MicDevice(uniqueID: $0.uniqueID, name: $0.localizedName) }
    }
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "transcribe.mic.capture")
    private let lock = NSLock()
    private var stopped = false
    private var firstPTS: CMTime?
    private var liveness = AudioLiveness()
    private var livenessReported = false
    private var watchdog: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []
    private let recorder: PCMTrackWriter
    public var onLog: (@Sendable (String) -> Void)?
    public var onLevel: (@Sendable (Double) -> Void)?
    public var onHealth: (@Sendable (CaptureHealth) -> Void)?
    public var onPart: (@Sendable (AudioSpan) -> Void)?
    public var onAudioFrame: (@Sendable (CapturedAudioFrame) -> Void)?
    public init(outputURL: URL, epoch: Double = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))) {
        recorder = PCMTrackWriter(directory: outputURL.deletingLastPathComponent(), source: .mic, epoch: epoch)
        super.init()
        recorder.onLevel = { [weak self] in self?.onLevel?($0) }
        recorder.onHealth = { [weak self] in self?.onHealth?($0) }
        recorder.onPart = { [weak self] in self?.onPart?($0) }
        recorder.onAudioFrame = { [weak self] in self?.onAudioFrame?($0) }
        for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.queue.async { [weak self] in
                    guard let self, !self.isStopped else { return }
                    self.reportInterruption("Microphone capture was interrupted. The saved audio is preserved.")
                }
            })
        }
    }
    deinit { watchdog?.cancel(); observers.forEach(NotificationCenter.default.removeObserver) }
    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    public var firstSamplePTS: CMTime? { queue.sync { firstPTS } }
    public var capturedSpans: [AudioSpan] { queue.sync { recorder.spans } }
    public var closedSpans: [AudioSpan] { queue.sync { recorder.closedSpans() } }
    @discardableResult
    public func start(uniqueID: String?) throws -> String {
        let name = try queue.sync {
            guard !isStopped else { throw CancellationError() }
            let device: AVCaptureDevice
            if let uniqueID {
                guard let chosen = AVCaptureDevice(uniqueID: uniqueID) else {
                    throw RuntimeError("The selected microphone is unavailable. Choose another microphone.")
                }
                device = chosen
            } else {
                guard let chosen = AVCaptureDevice.default(for: .audio) else { throw RuntimeError("No microphone is available.") }
                device = chosen
            }
            onHealth?(CaptureHealth(source: .mic, state: .starting))
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input), session.canAddOutput(output) else {
                throw RuntimeError("The microphone could not be configured.")
            }
            session.addInput(input); session.addOutput(output)
            output.setSampleBufferDelegate(self, queue: queue)
            return device.localizedName
        }
        try beginRunning()
        return name
    }
    fileprivate func beginRunning() throws {
        try queue.sync {
            guard !isStopped else { throw CancellationError() }
            session.startRunning()
            if isStopped { session.stopRunning(); throw CancellationError() }
            guard session.isRunning else { throw RuntimeError("The microphone could not start.") }
            liveness.start(at: captureHostSeconds())
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in
                guard let self, !self.isStopped else { return }
                self.checkLiveness()
            }
            watchdog = timer; timer.resume()
        }
    }
    private func reportInterruption(_ message: String) {
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
                self.session.stopRunning()
                _ = self.recorder.stop()
                self.onLevel?(0)
                continuation.resume()
            }
        }
    }
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        guard !isStopped, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        liveness.received(at: captureHostSeconds())
        guard let pcm = SystemAudioCapture.makePCMBuffer(from: sampleBuffer) else {
            reportInterruption("Microphone audio could not be decoded."); return
        }
        if firstPTS == nil { firstPTS = sampleBuffer.presentationTimeStamp }
        do { try recorder.append(pcm, pts: CMTimeGetSeconds(sampleBuffer.presentationTimeStamp)) }
        catch {
            onHealth?(CaptureHealth(source: .mic, state: .interrupted, message: "Microphone audio could not be saved."))
            onLog?("Microphone audio could not be saved.")
        }
    }
    public func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        onHealth?(CaptureHealth(source: .mic, state: .interrupted, message: "Microphone audio was interrupted."))
    }
}
