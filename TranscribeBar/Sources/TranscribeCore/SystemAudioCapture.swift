import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia

@available(macOS 13.0, *)
public final class SystemAudioCapture: NSObject, SCStreamDelegate, SCStreamOutput, @unchecked Sendable {
    public enum CaptureError: Error, LocalizedError {
        case noDisplay, stopped
        public var errorDescription: String? {
            switch self {
            case .noDisplay: return "Mac audio is unavailable. Check Screen & System Audio Recording permission."
            case .stopped: return "Audio capture was stopped."
            }
        }
    }
    private var stream: SCStream?
    private let writeQueue = DispatchQueue(label: "transcribe.syscap.write")
    private let lock = NSLock()
    private var stopped = false
    private var firstPTS: CMTime?
    private var liveness = AudioLiveness()
    private var lastLivenessFailure: AudioLiveness.Failure?
    private var watchdog: DispatchSourceTimer?
    private let recorder: PCMTrackWriter
    public var onLog: (@Sendable (String) -> Void)?
    public var onFirstBuffer: (@Sendable () -> Void)?
    public var onLevel: (@Sendable (Double) -> Void)?
    public var onHealth: (@Sendable (CaptureHealth) -> Void)?
    public var onPart: (@Sendable (AudioSpan) -> Void)?
    public init(outputURL: URL, epoch: Double = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))) {
        recorder = PCMTrackWriter(directory: outputURL.deletingLastPathComponent(), source: .system, epoch: epoch)
        super.init()
        recorder.onLevel = { [weak self] in self?.onLevel?($0) }
        recorder.onHealth = { [weak self] in self?.onHealth?($0) }
        recorder.onPart = { [weak self] in self?.onPart?($0) }
    }
    deinit { watchdog?.cancel() }
    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    public var firstSamplePTS: CMTime? { writeQueue.sync { firstPTS } }
    public var capturedSpans: [AudioSpan] { writeQueue.sync { recorder.spans } }
    public var closedSpans: [AudioSpan] { writeQueue.sync { recorder.closedSpans() } }
    public struct Summary: Sendable {
        public let buffers: Int
        public let seconds: Double
        public let nonSilent: Bool
    }
    public func start() async throws {
        guard !isStopped else { throw CancellationError() }
        onHealth?(CaptureHealth(source: .system, state: .starting))
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard !isStopped else { throw CancellationError() }
        guard let display = content.displays.first else { throw CaptureError.noDisplay }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true; config.sampleRate = 48_000; config.channelCount = 2
        config.excludesCurrentProcessAudio = true
        config.width = 128; config.height = 128
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false; config.queueDepth = 5
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "transcribe.syscap.audio"))
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "transcribe.syscap.screen"))
        lock.withLock { self.stream = stream }
        guard !isStopped else { throw CancellationError() }
        writeQueue.sync { liveness.start(at: captureHostSeconds()); lastLivenessFailure = nil }
        try await stream.startCapture()
        if isStopped { try? await stream.stopCapture(); throw CancellationError() }
        writeQueue.sync {
            guard !isStopped else { return }
            let timer = DispatchSource.makeTimerSource(queue: writeQueue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in
                guard let self, !self.isStopped else { return }
                self.checkLiveness()
            }
            watchdog = timer; timer.resume()
        }
    }
    private func checkLiveness() {
        guard let failure = liveness.failure(at: captureHostSeconds()), failure != lastLivenessFailure else { return }
        lastLivenessFailure = failure; onLevel?(0)
        if failure == .noBuffers {
            // A quiet Mac may never send a first buffer. Mic previews continue,
            // but this is not evidence that system audio was successfully captured.
            onHealth?(CaptureHealth(source: .system, state: .silent, message: "No Mac audio has arrived yet."))
        } else {
            onHealth?(CaptureHealth(source: .system, state: .interrupted,
                message: "Mac audio stopped arriving. Your microphone is still recording."))
        }
    }
    @discardableResult
    public func stop() async -> Summary {
        let currentStream = lock.withLock { stopped = true; return stream }
        writeQueue.sync {
            checkLiveness()
            watchdog?.cancel(); watchdog = nil
        }
        try? await currentStream?.stopCapture()
        return writeQueue.sync {
            _ = recorder.stop(); onLevel?(0)
            return Summary(buffers: recorder.bufferCount, seconds: recorder.spans.reduce(0) { $0 + $1.duration }, nonSilent: recorder.sawSignal)
        }
    }
    public func restart(shouldContinue: @Sendable () -> Bool = { true }) async throws {
        _ = await stop()
        let allowed = lock.withLock { () -> Bool in
            guard shouldContinue() else { return false }
            stopped = false
            return true
        }
        guard allowed else { throw CancellationError() }
        try await start()
    }
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, !isStopped, sampleBuffer.isValid,
              let pcm = Self.makePCMBuffer(from: sampleBuffer) else { return }
        let pts = sampleBuffer.presentationTimeStamp
        writeQueue.async { [weak self] in
            guard let self, !self.isStopped else { return }
            self.liveness.received(at: captureHostSeconds())
            if self.lastLivenessFailure != nil {
                self.lastLivenessFailure = nil
                self.onHealth?(CaptureHealth(source: .system, state: .active))
            }
            if self.firstPTS == nil { self.firstPTS = pts; self.onFirstBuffer?() }
            do { try self.recorder.append(pcm, pts: CMTimeGetSeconds(pts)) }
            catch {
                self.onHealth?(CaptureHealth(source: .system, state: .interrupted, message: "Mac audio could not be saved."))
                self.onLog?("Mac audio could not be saved.")
            }
        }
    }
    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard !isStopped else { return }
        onHealth?(CaptureHealth(source: .system, state: .interrupted, message: "Mac audio stopped. Retry Mac audio to continue."))
        onLevel?(0)
    }

    static func makePCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let fmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc)
        else { return nil }
        var asbd = asbdPtr.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0 else { return nil }
        do {
            return try sampleBuffer.withAudioBufferList { srcList, _ -> AVAudioPCMBuffer? in
                guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
                out.frameLength = frames
                let dstList = UnsafeMutableAudioBufferListPointer(out.mutableAudioBufferList)
                let n = min(dstList.count, srcList.count)
                for i in 0..<n {
                    if let sData = srcList[i].mData, let dData = dstList[i].mData {
                        memcpy(dData, sData, Int(min(srcList[i].mDataByteSize, dstList[i].mDataByteSize)))
                    }
                }
                return out
            }
        } catch { return nil }
    }

    static func bufferHasSignal(_ buf: AVAudioPCMBuffer) -> Bool {
        guard let channels = buf.floatChannelData else { return false }
        let frames = Int(buf.frameLength)
        for c in 0..<Int(buf.format.channelCount) {
            let p = channels[c]
            for i in 0..<frames where abs(p[i]) > 1e-4 { return true }
        }
        return false
    }
}
