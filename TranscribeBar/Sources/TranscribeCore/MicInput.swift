import Foundation
import AVFoundation
import CoreMedia

public struct MicrophoneCaptureError: Error, LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

/// A running capture session is not proof of recording. Wait off the capture queue
/// until the writer has actually saved samples, or an interruption/timeout wins.
final class MicrophoneStartup {
    private let lock = NSLock()
    private let signal = DispatchSemaphore(value: 0)
    private var result: Result<Void, MicrophoneCaptureError>?

    func recordedAudio() { resolve(.success(())) }
    func failed(_ message: String) { resolve(.failure(MicrophoneCaptureError(message: message))) }
    private func resolve(_ value: Result<Void, MicrophoneCaptureError>) {
        let resolved = lock.withLock { () -> Bool in
            guard result == nil else { return false }
            result = value; return true
        }
        if resolved { signal.signal() }
    }
    func wait(timeout: DispatchTimeInterval = .seconds(3)) throws {
        _ = signal.wait(timeout: .now() + timeout)
        failed("No microphone audio arrived. Connect a microphone and check its permission.")
        try lock.withLock { try result!.get() }
    }
}

/// Where microphone buffers come from. `MicCapture` owns everything downstream
/// (track writing, liveness, levels, health); an input only delivers audio.
///
/// Both callbacks run on the capture queue the input was created with.
/// The time passed to `onBuffer` is host-clock seconds, the clock of the capture epoch.
protocol MicInput: AnyObject {
    var onBuffer: ((AVAudioPCMBuffer, Double) -> Void)? { get set }
    var onInterruption: ((String) -> Void)? { get set }
    /// Starts delivering audio from `device`. `explicitlySelected` is false when `device`
    /// is simply the system default input. Throws without leaving anything running.
    func start(device: AVCaptureDevice, explicitlySelected: Bool) throws
    /// Idempotent. Buffers may still arrive on the queue briefly afterwards.
    func stop()
}

/// The raw microphone via AVCaptureSession: no echo cancellation or other processing.
@available(macOS 13.0, *)
final class CaptureSessionMicInput: NSObject, MicInput, AVCaptureAudioDataOutputSampleBufferDelegate {
    var onBuffer: ((AVAudioPCMBuffer, Double) -> Void)?
    var onInterruption: ((String) -> Void)?
    private let queue: DispatchQueue
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private var observers: [NSObjectProtocol] = []

    init(queue: DispatchQueue) {
        self.queue = queue
        super.init()
        for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) { [weak self] _ in
                self?.queue.async { self?.onInterruption?("Microphone capture was interrupted. The saved audio is preserved.") }
            })
        }
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func start(device: AVCaptureDevice, explicitlySelected: Bool) throws {
        try configure(device)
        session.startRunning()
        guard session.isRunning else { throw RuntimeError("The microphone could not start.") }
    }
    private func configure(_ device: AVCaptureDevice) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw RuntimeError("The microphone could not be configured.")
        }
        session.addInput(input); session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: queue)
    }
    func stop() { session.stopRunning() }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let pcm = SystemAudioCapture.makePCMBuffer(from: sampleBuffer) else {
            onInterruption?("Microphone audio could not be decoded."); return
        }
        onBuffer?(pcm, CMTimeGetSeconds(sampleBuffer.presentationTimeStamp))
    }
    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        onInterruption?("Microphone audio was interrupted.")
    }
}
