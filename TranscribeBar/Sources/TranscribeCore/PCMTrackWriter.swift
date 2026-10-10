import Foundation
import AVFoundation

/// All calls are confined to the owning capture queue. Parts have exact host-clock offsets;
/// discontinuities become separate spans, rather than compressed-away missing audio.
final class PCMTrackWriter {
    let directory: URL
    let source: Source
    let epoch: Double
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var framesInPart = 0
    private var expectedPTS: Double?
    private var lastManifestTime = 0.0
    private(set) var spans: [AudioSpan] = []
    private(set) var sawSignal = false
    private(set) var bufferCount = 0
    var onLevel: ((Double) -> Void)?
    var onPart: ((AudioSpan) -> Void)?
    var onHealth: ((CaptureHealth) -> Void)?
    private var lastHealth: CaptureHealthState?
    static let rate = 16_000.0
    static let partFrames = 720_000 // 45 seconds
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!

    init(directory: URL, source: Source, epoch: Double) {
        self.directory = directory; self.source = source; self.epoch = epoch
    }
    func append(_ input: AVAudioPCMBuffer, pts: Double) throws {
        guard pts.isFinite else { throw RuntimeError("Audio capture returned an invalid clock.") }
        let inputDuration = Double(input.frameLength) / input.format.sampleRate
        if let expectedPTS, abs(pts - expectedPTS) > 0.12 {
            finishPart()
            health(.interrupted, message: "An audio gap was detected. The captured sections are preserved.")
        }
        expectedPTS = pts + inputDuration
        if inputFormat != input.format {
            inputFormat = input.format
            converter = AVAudioConverter(from: input.format, to: format)
        }
        guard let converter else { throw RuntimeError("The audio input format is unsupported.") }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * Self.rate / input.format.sampleRate) + 64)
        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw RuntimeError("Audio buffering failed.")
        }
        var supplied = false
        var conversionError: NSError?
        let result = converter.convert(to: converted, error: &conversionError) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return input
        }
        guard conversionError == nil, result != .error else { throw RuntimeError("Audio conversion failed.") }
        guard converted.frameLength > 0, let samples = converted.floatChannelData?[0] else { return }
        bufferCount += 1
        var energy = 0.0
        for i in 0..<Int(converted.frameLength) { energy += Double(samples[i] * samples[i]) }
        let rms = sqrt(energy / Double(converted.frameLength))
        let level = min(1, rms * 8)
        onLevel?(level)
        if rms > 0.0001 { sawSignal = true; health(.active) } else { health(.silent) }
        var consumed = 0
        while consumed < Int(converted.frameLength) {
            if file == nil {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let prefix = source == .mic ? "mic" : "system"
                let url = directory.appendingPathComponent(String(format: "%@_part_%05d.wav", prefix, spans.count))
                guard !FileManager.default.fileExists(atPath: url.path) else {
                    throw RuntimeError("This folder already contains a recording. Choose a new recording folder.")
                }
                file = try AVAudioFile(forWriting: url, settings: format.settings)
                framesInPart = 0
                spans.append(AudioSpan(url: url, offset: max(0, pts - epoch + Double(consumed) / Self.rate), duration: 0))
                try persistManifest()
            }
            let count = min(Self.partFrames - framesInPart, Int(converted.frameLength) - consumed)
            guard let portion = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                  let dest = portion.floatChannelData?[0] else { throw RuntimeError("Audio buffering failed.") }
            portion.frameLength = AVAudioFrameCount(count)
            dest.update(from: samples + consumed, count: count)
            try file?.write(from: portion)
            consumed += count; framesInPart += count
            spans[spans.count - 1].duration = Double(framesInPart) / Self.rate
            if framesInPart == Self.partFrames { finishPart() }
        }
        if pts - lastManifestTime >= 1 { try persistManifest(); lastManifestTime = pts }
    }
    func stop() -> [AudioSpan] { finishPart(); return spans }
    func closedSpans() -> [AudioSpan] { file == nil ? spans : Array(spans.dropLast()) }
    private func health(_ state: CaptureHealthState, message: String? = nil) {
        guard lastHealth != state else { return }
        lastHealth = state; onHealth?(CaptureHealth(source: source, state: state, message: message))
    }
    private func finishPart() {
        guard file != nil else { return }
        file = nil
        do { try persistManifest() } catch { health(.interrupted, message: "Audio metadata could not be saved.") }
        if let span = spans.last, span.duration > 0 { onPart?(span) }
    }
    private func persistManifest() throws {
        let prefix = source == .mic ? "mic" : "system"
        try JSONEncoder().encode(SessionAudioTrack(source: source, spans: spans))
            .write(to: directory.appendingPathComponent(prefix + "-capture.json"), options: .atomic)
    }
}

public func recoverTracks(in directory: URL) -> [SessionAudioTrack] { recoverSessionAudioTracks(in: directory) }

func recoverSessionAudioTracks(in directory: URL) -> [SessionAudioTrack] {
    ["mic-capture.json", "system-capture.json"].compactMap { name in
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
              let track = try? JSONDecoder().decode(SessionAudioTrack.self, from: data) else { return nil }
        // Keep incomplete parts referenced as well. A later retry reports unreadable audio
        // explicitly; recovery must never erase evidence of a missing section.
        var recovered = track
        recovered.spans = track.spans.map { span in
            guard let audio = try? AVAudioFile(forReading: span.url), audio.processingFormat.sampleRate > 0 else { return span }
            return AudioSpan(url: span.url, offset: span.offset,
                             duration: Double(audio.length) / audio.processingFormat.sampleRate)
        }
        return recovered
    }
}
