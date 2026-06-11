import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia

/// Captures macOS *system output* audio via ScreenCaptureKit (the remote participants),
/// folded in from the standalone SystemAudioRecorder CLI. Writes a float WAV/CAF and records
/// the first audio buffer's presentation timestamp (host-time clock) so the mic track can be
/// aligned sample-accurately. macOS 13+.
@available(macOS 13.0, *)
public final class SystemAudioCapture: NSObject, SCStreamDelegate, SCStreamOutput, @unchecked Sendable {

    public enum CaptureError: Error, CustomStringConvertible {
        case noDisplay
        public var description: String {
            switch self {
            case .noDisplay:
                return "No display available — this almost always means Screen Recording "
                     + "permission is missing for this app (System Settings ▸ Privacy & Security "
                     + "▸ Screen & System Audio Recording)."
            }
        }
    }

    private let outputURL: URL
    private var stream: SCStream?
    private var audioFile: AVAudioFile?
    private let writeQueue = DispatchQueue(label: "transcribe.syscap.write")

    // All mutable state below is touched only on writeQueue.
    private var buffersReceived = 0
    private var framesWritten: AVAudioFrameCount = 0
    private var sawNonSilentAudio = false
    private var loggedDecodeFailure = false
    private var firstPTS: CMTime?
    private var firstBufferFired = false

    /// Optional diagnostics sink (defaults to stderr). The app routes this to its log/UI.
    public var onLog: (@Sendable (String) -> Void)?
    /// Fired once, on the first decoded audio buffer (the in-process successor to the
    /// stdout READY handshake) — the controller starts the mic here.
    public var onFirstBuffer: (@Sendable () -> Void)?

    public init(outputURL: URL) {
        self.outputURL = outputURL
    }

    private func log(_ s: String) {
        if let onLog { onLog(s) }
        else { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
    }

    /// First audio buffer's presentation timestamp on the host-time clock, or nil if no
    /// audio has arrived yet. Compared PTS-to-PTS with the mic's first PTS for the offset.
    public var firstSamplePTS: CMTime? { writeQueue.sync { firstPTS } }

    public struct Summary: Sendable {
        public let buffers: Int
        public let seconds: Double
        public let nonSilent: Bool
    }

    public func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw CaptureError.noDisplay }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true
        // SCK has no audio-only mode; a degenerate frame trips -3805 on macOS 15+, so keep a
        // small valid frame at a low frame rate.
        config.width = 128
        config.height = 128
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false
        config.queueDepth = 5

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio,
                                   sampleHandlerQueue: DispatchQueue(label: "transcribe.syscap.audio"))
        // SCK delivers audio reliably only when a screen output also exists; frames ignored.
        try stream.addStreamOutput(self, type: .screen,
                                   sampleHandlerQueue: DispatchQueue(label: "transcribe.syscap.screen"))
        self.stream = stream
        try await stream.startCapture()

        writeQueue.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            if self.buffersReceived == 0 {
                self.log("WARNING: no system-audio buffers after 3s — check Screen Recording permission, or nothing is playing.")
            }
        }
    }

    @discardableResult
    public func stop() async -> Summary {
        try? await stream?.stopCapture()
        return writeQueue.sync {
            let seconds = Double(framesWritten) / 48_000.0
            audioFile = nil   // flush / close
            let status = buffersReceived == 0
                ? "NO audio buffers — Screen Recording permission likely missing"
                : (sawNonSilentAudio ? "non-silent ✓" : "SILENT (all-zero) — check permission / playback")
            log(String(format: "system audio: %d buffers, %.1fs — %@", buffersReceived, seconds, status))
            return Summary(buffers: buffersReceived, seconds: seconds, nonSilent: sawNonSilentAudio)
        }
    }

    // MARK: - SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                       of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        let pts = sampleBuffer.presentationTimeStamp
        guard let pcm = SystemAudioCapture.makePCMBuffer(from: sampleBuffer) else {
            writeQueue.async { [weak self] in
                guard let self, !self.loggedDecodeFailure else { return }
                self.loggedDecodeFailure = true
                self.log("WARNING: failed to decode an audio buffer (further warnings suppressed)")
            }
            return
        }
        let nonSilent = SystemAudioCapture.bufferHasSignal(pcm)
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.buffersReceived += 1
            if !self.firstBufferFired {
                self.firstBufferFired = true
                self.firstPTS = pts
                self.onFirstBuffer?()
            }
            if nonSilent { self.sawNonSilentAudio = true }
            do {
                if self.audioFile == nil {
                    let settings: [String: Any] = [
                        AVFormatIDKey: kAudioFormatLinearPCM,
                        AVSampleRateKey: pcm.format.sampleRate,
                        AVNumberOfChannelsKey: pcm.format.channelCount,
                        AVLinearPCMBitDepthKey: 32,
                        AVLinearPCMIsFloatKey: true,
                        AVLinearPCMIsBigEndianKey: false,
                    ]
                    self.audioFile = try AVAudioFile(forWriting: self.outputURL, settings: settings,
                                                     commonFormat: pcm.format.commonFormat,
                                                     interleaved: pcm.format.isInterleaved)
                }
                try self.audioFile?.write(from: pcm)
                self.framesWritten += pcm.frameLength
            } catch {
                self.log("write error: \(error)")
            }
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        let ns = error as NSError
        log("stream stopped with error: \(error) [\(ns.domain) \(ns.code)]")
    }

    // MARK: - helpers

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
