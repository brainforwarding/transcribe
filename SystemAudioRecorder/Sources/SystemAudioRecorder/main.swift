// SystemAudioRecorder
// Captures macOS *system output* audio (everything coming out of your speakers /
// headphones — i.e. the other people on a call) using ScreenCaptureKit.
// No BlackHole / virtual device needed. Requires macOS 13+.
//
// It does NOT capture your microphone — that is handled separately by meetrec.py,
// which records the mic in parallel and mixes the two afterwards.
//
// Usage:  SystemAudioRecorder /path/to/system.wav
// Stop:   send SIGINT (Ctrl-C). The file is finalized on stop.
//
// On exit it prints a one-line summary (buffers / seconds / silent-or-not) to
// stderr so you can tell a permission/silence problem apart from a real recording.

import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia

@available(macOS 13.0, *)
// `@unchecked Sendable`: every piece of mutable state (`audioFile` + the counters)
// is touched only on `writeQueue`, so the class is safe to hand to the dispatch
// closures below even though the compiler can't prove that confinement itself.
final class SystemAudioRecorder: NSObject, SCStreamDelegate, SCStreamOutput, @unchecked Sendable {

    private let outputURL: URL
    private var stream: SCStream?
    private var audioFile: AVAudioFile?
    // A single serial queue owns `audioFile` and all the diagnostic counters below,
    // so the audio callback, the watchdog, and stop() never race on them.
    private let writeQueue = DispatchQueue(label: "syscap.write")

    // Diagnostics — only touched on writeQueue.
    private var buffersReceived = 0
    private var framesWritten: AVAudioFrameCount = 0
    private var sawNonSilentAudio = false
    private var loggedDecodeFailure = false

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    func start() async throws {
        // Pick a display to attach the capture to. We are only after audio, so the
        // display choice is irrelevant — but ScreenCaptureKit has no audio-only mode
        // and still requires a content filter built from shareable content.
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw NSError(domain: "syscap", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "No display available to attach capture to. If a display IS connected, this "
                + "almost always means Screen Recording permission is missing — grant it to "
                + "your terminal app in System Settings ▸ Privacy & Security ▸ Screen & System "
                + "Audio Recording, then quit and reopen the terminal."])
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // Don't record the sound this very process might make.
        config.excludesCurrentProcessAudio = true
        // We never use the video, but SCK has no audio-only mode. A degenerate size
        // (e.g. 2x2) is a known trigger for "stream starts then immediately stops"
        // (SCStreamErrorDomain -3805) on macOS 15+, so keep a small *valid* frame at a
        // low frame rate to stay cheap without tripping that path.
        config.width = 128
        config.height = 128
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)   // ~1 fps
        config.showsCursor = false
        config.queueDepth = 5

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        // Audio is what we want.
        try stream.addStreamOutput(self, type: .audio,
                                   sampleHandlerQueue: DispatchQueue(label: "syscap.audio"))
        // SCK delivers audio reliably only when a screen output also exists; we ignore
        // its frames (the callback drops everything that isn't `.audio`).
        try stream.addStreamOutput(self, type: .screen,
                                   sampleHandlerQueue: DispatchQueue(label: "syscap.screen"))

        self.stream = stream
        try await stream.startCapture()

        // Watchdog: if no audio buffer has arrived a few seconds in, the capture
        // "succeeded" but is delivering nothing — overwhelmingly a missing/again-revoked
        // Screen Recording grant. Surface that instead of silently writing an empty file.
        writeQueue.asyncAfter(deadline: .now() + 3) {
            if self.buffersReceived == 0 {
                FileHandle.standardError.write(
                    ("WARNING: no system-audio buffers after 3s. Either nothing is playing, or "
                     + "Screen Recording permission is missing for your terminal — grant it in "
                     + "System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording, "
                     + "then quit and reopen the terminal.\n").data(using: .utf8)!)
            }
        }
    }

    func stop() async {
        try? await stream?.stopCapture()
        writeQueue.sync {
            let seconds = Double(self.framesWritten) / 48_000.0
            self.audioFile = nil   // flush / close
            let status: String
            if self.buffersReceived == 0 {
                status = "NO audio buffers — Screen Recording permission is most likely missing"
            } else if !self.sawNonSilentAudio {
                status = "SILENT (all-zero) — check permission / that audio was actually playing"
            } else {
                status = "non-silent ✓"
            }
            FileHandle.standardError.write(
                String(format: "system audio: %d buffers, %.1fs written — %@\n",
                       self.buffersReceived, seconds, status).data(using: .utf8)!)
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        guard let pcm = Self.makePCMBuffer(from: sampleBuffer) else {
            writeQueue.async {
                if !self.loggedDecodeFailure {
                    self.loggedDecodeFailure = true
                    FileHandle.standardError.write(
                        "WARNING: failed to decode an audio buffer (further such warnings suppressed)\n"
                            .data(using: .utf8)!)
                }
            }
            return
        }

        let nonSilent = Self.bufferHasSignal(pcm)
        writeQueue.async {
            self.buffersReceived += 1
            if self.buffersReceived == 1 {
                // Signal the orchestrator (meetrec.py) that the system tap is live, so it
                // can start the mic recorder now — this bounds the inter-track offset to
                // ffmpeg's small startup lag instead of SCK's ~1–2 s warmup. stdout is
                // unbuffered via FileHandle; all other diagnostics go to stderr.
                FileHandle.standardOutput.write("READY\n".data(using: .utf8)!)
            }
            if nonSilent { self.sawNonSilentAudio = true }
            do {
                if self.audioFile == nil {
                    // Write a float32 WAV. The on-disk file is interleaved (what WAV
                    // requires — so CoreAudio doesn't log a "cannot be non-interleaved"
                    // note), while the *processing* format is taken from the buffer, which
                    // ScreenCaptureKit delivers as non-interleaved Float32. Matching the
                    // processing format to the buffer is what stops write(from:) throwing
                    // or scrambling channels on a layout mismatch.
                    let fileSettings: [String: Any] = [
                        AVFormatIDKey: kAudioFormatLinearPCM,
                        AVSampleRateKey: pcm.format.sampleRate,
                        AVNumberOfChannelsKey: pcm.format.channelCount,
                        AVLinearPCMBitDepthKey: 32,
                        AVLinearPCMIsFloatKey: true,
                        AVLinearPCMIsBigEndianKey: false,
                    ]
                    self.audioFile = try AVAudioFile(
                        forWriting: self.outputURL,
                        settings: fileSettings,
                        commonFormat: pcm.format.commonFormat,
                        interleaved: pcm.format.isInterleaved)
                }
                try self.audioFile?.write(from: pcm)
                self.framesWritten += pcm.frameLength
            } catch {
                FileHandle.standardError.write(
                    "write error: \(error)\n".data(using: .utf8)!)
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let ns = error as NSError
        FileHandle.standardError.write(
            "stream stopped with error: \(error) [\(ns.domain) \(ns.code)]\n".data(using: .utf8)!)
    }

    // MARK: - CMSampleBuffer -> AVAudioPCMBuffer

    /// Copies the PCM out of an audio CMSampleBuffer into a freshly-owned
    /// AVAudioPCMBuffer. We copy (rather than wrap the sample buffer's memory with
    /// `bufferListNoCopy`) so the buffer stays valid after it's handed to the write
    /// queue — `withAudioBufferList`'s pointer is only alive inside the closure.
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
                guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
                else { return nil }
                out.frameLength = frames
                let dstList = UnsafeMutableAudioBufferListPointer(out.mutableAudioBufferList)
                let n = min(dstList.count, srcList.count)
                for i in 0..<n {
                    let src = srcList[i]
                    let dst = dstList[i]
                    if let sData = src.mData, let dData = dst.mData {
                        let bytes = Int(min(src.mDataByteSize, dst.mDataByteSize))
                        memcpy(dData, sData, bytes)
                    }
                }
                return out
            }
        } catch {
            return nil
        }
    }

    /// True if any sample in the (non-interleaved float) buffer is above a tiny floor.
    /// Used only to label the recording silent vs. non-silent at stop time.
    static func bufferHasSignal(_ buf: AVAudioPCMBuffer) -> Bool {
        guard let channels = buf.floatChannelData else { return false }
        let frames = Int(buf.frameLength)
        for c in 0..<Int(buf.format.channelCount) {
            let p = channels[c]
            for i in 0..<frames where abs(p[i]) > 1e-4 {
                return true
            }
        }
        return false
    }
}

// MARK: - main

guard #available(macOS 13.0, *) else {
    FileHandle.standardError.write("SystemAudioRecorder requires macOS 13 or later.\n".data(using: .utf8)!)
    exit(1)
}

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "system.wav"
let recorder = SystemAudioRecorder(outputURL: URL(fileURLWithPath: outPath))
let done = DispatchSemaphore(value: 0)

// Clean shutdown on Ctrl-C so the WAV is finalized.
signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
sigint.setEventHandler {
    Task {
        await recorder.stop()
        FileHandle.standardError.write("\nStopped. Saved system audio to \(outPath)\n".data(using: .utf8)!)
        done.signal()
    }
}
sigint.resume()

Task {
    do {
        try await recorder.start()
        FileHandle.standardError.write("Recording system audio… (Ctrl-C to stop)\n".data(using: .utf8)!)
    } catch {
        FileHandle.standardError.write("Failed to start capture: \(error)\n".data(using: .utf8)!)
        FileHandle.standardError.write(
            ("If that error mentions permission or declined access, grant Screen Recording to "
             + "your terminal app and reopen it.\n").data(using: .utf8)!)
        exit(1)
    }
}

done.wait()
exit(0)
