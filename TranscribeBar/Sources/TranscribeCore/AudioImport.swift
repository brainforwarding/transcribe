import Foundation
import AVFoundation

public enum AudioImportError: Error, Sendable, Equatable {
    case unsupportedFormat, noAudio
}

/// Leftover import folders from another process are crash debris; this process's own
/// are imports in progress, so a reload never deletes them.
let importFolderPrefix = ".import-"
let importProcessToken = UUID().uuidString
private let importRate = 16_000.0
private let importPartFrames = 720_000 // 45 s, as the live recorder

extension SessionStore {
    /// Prepares a dropped file as an in-person meeting or a dictation with status `.processing`
    /// and saves it. The source is only read. On any failure nothing is left in the store.
    public func importAudioFile(_ source: URL, kind: SessionKind = .meeting, languages: [String] = [],
                                keywords: [String] = [], now: Date = Date()) async throws -> SessionRecord {
        let fm = FileManager.default
        let temporary = root.appendingPathComponent(importFolderPrefix + importProcessToken + "-" + UUID().uuidString, isDirectory: true)
        let stem = source.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        var record = SessionRecord(kind: kind, meetingMode: .inPerson, title: stem.isEmpty ? (kind == .meeting ? "Meeting" : "Dictation") : stem,
                                   startedAt: now, languages: languages, keywords: keywords)
        record.importedFrom = source.lastPathComponent
        let final = directory(for: record.id)
        var moved = false
        do {
            try fm.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let magic = try FileHandle(forReadingFrom: source).readOnlyPrefix(4)
            if magic == Data("OggS".utf8) {
                try fm.copyItem(at: source, to: temporary.appendingPathComponent("audio.ogg"))
                record.importedAudio = final.appendingPathComponent("audio.ogg")
            } else {
                guard magic != Data([0x1A, 0x45, 0xDF, 0xA3]) else { throw AudioImportError.unsupportedFormat }
                let spans = try await decodeImportedAudio(source, into: temporary, finalDirectory: final)
                record.tracks = [SessionAudioTrack(source: .mic, spans: spans)]
                record.duration = spans.last.map { $0.offset + $0.duration } ?? 0
            }
            record.status = .processing; record.delivery = .never; record.titleIsAutomatic = kind == .meeting
            try Task.checkCancellation()
            try fm.moveItem(at: temporary, to: final); moved = true
            try save(record)
            return record
        } catch {
            try? fm.removeItem(at: temporary)
            if moved { try? fm.removeItem(at: final) }
            throw error
        }
    }

    func removeStaleImports() {
        let fm = FileManager.default
        for dir in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        where dir.lastPathComponent.hasPrefix(importFolderPrefix) && !dir.lastPathComponent.hasPrefix(importFolderPrefix + importProcessToken) {
            try? fm.removeItem(at: dir)
        }
    }
}

private extension FileHandle {
    func readOnlyPrefix(_ count: Int) throws -> Data {
        defer { try? close() }
        return try read(upToCount: count) ?? Data()
    }
}

/// Writes the same 16 kHz mono float WAV parts as the live recorder, with span URLs
/// already pointing at `finalDirectory`, where `directory` is renamed after preparing.
func decodeImportedAudio(_ source: URL, into directory: URL, finalDirectory: URL) async throws -> [AudioSpan] {
    let asset = AVURLAsset(url: source)
    let tracks: [AVAssetTrack]
    do { tracks = try await asset.loadTracks(withMediaType: .audio) } catch { throw AudioImportError.unsupportedFormat }
    guard !tracks.isEmpty else { throw AudioImportError.noAudio }
    let reader: AVAssetReader
    do { reader = try AVAssetReader(asset: asset) } catch { throw AudioImportError.unsupportedFormat }
    // The mix output sums every audio track and downmixes channels; a track output
    // would keep only one track of a multi-track movie.
    let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: importRate, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
    ])
    guard reader.canAdd(output) else { throw AudioImportError.unsupportedFormat }
    reader.add(output)
    guard reader.startReading() else { throw AudioImportError.unsupportedFormat }
    defer { if reader.status == .reading { reader.cancelReading() } }
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: importRate, channels: 1, interleaved: false)!
    var spans: [AudioSpan] = []
    var file: AVAudioFile?
    var framesInPart = 0
    var total = 0
    while let sample = output.copyNextSampleBuffer() {
        try Task.checkCancellation()
        guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
        let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
        guard count > 0 else { continue }
        var samples = [Float](repeating: 0, count: count)
        guard samples.withUnsafeMutableBytes({ CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }) == kCMBlockBufferNoErr
        else { throw AudioImportError.unsupportedFormat }
        var consumed = 0
        while consumed < count {
            if file == nil {
                let name = String(format: "mic_part_%05d.wav", spans.count)
                file = try AVAudioFile(forWriting: directory.appendingPathComponent(name), settings: format.settings)
                spans.append(AudioSpan(url: finalDirectory.appendingPathComponent(name), offset: Double(total) / importRate, duration: 0))
                framesInPart = 0
            }
            let portion = min(importPartFrames - framesInPart, count - consumed)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(portion)) else {
                throw RuntimeError("Audio buffering failed.")
            }
            buffer.frameLength = AVAudioFrameCount(portion)
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress! + consumed, count: portion) }
            try file?.write(from: buffer)
            consumed += portion; framesInPart += portion; total += portion
            spans[spans.count - 1].duration = Double(framesInPart) / importRate
            if framesInPart == importPartFrames { file = nil }
        }
    }
    file = nil
    guard reader.status == .completed else { throw AudioImportError.unsupportedFormat }
    guard total > 0 else { throw AudioImportError.noAudio }
    return spans
}

extension FinalTranscription {
    /// The length of an imported Ogg file, which is known only from its transcript.
    public var lastSegmentEnd: Double { segments.map(\.end).max() ?? 0 }
}

/// An Ogg file goes up whole, as one request, mapped exactly like one mic chunk in
/// `transcribeFinal`: diarized turns for a meeting, plain text for a dictation.
public func transcribeImportedAudio(_ url: URL, chunkDir: URL, kind: TranscriptionKind = .inPersonMeeting,
                                    languages: [String] = [], keywords: [String] = [], config: OpenAIConfig,
                                    session: URLSession = .shared) async throws -> FinalTranscription {
    let identity: String
    do { identity = try audioDigest(url) } catch {
        return FinalTranscription(text: "", segments: [], complete: false, issues: [TranscriptionIssue(source: .mic,
            userMessage: "A captured audio source could not be read. The recording is kept.", retryable: true, failureKind: .storage)])
    }
    do {
        let response = try await cachedAudioTranscript(fileURL: url, model: kind == .dictation ? .text : .diarized,
            languages: languages, keywords: kind == .dictation ? keywords : [],
            cacheDir: chunkDir.appendingPathComponent("transcript-cache", isDirectory: true), prompt: nil,
            config: config, session: session, audioIdentity: identity)
        if kind == .dictation {
            return FinalTranscription(text: response.text.trimmingCharacters(in: .whitespacesAndNewlines), segments: [], complete: true, issues: [])
        }
        var turns: [Segment] = []
        for (turnIndex, turn) in response.segments.enumerated() {
            let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            turns.append(Segment(start: turn.start, end: turn.end, label: "Microphone", text: text, source: .mic,
                                 idx: Source.mic.rawValue * 1_000_000_000 + turnIndex))
        }
        turns.sort { $0.start != $1.start ? $0.start < $1.start : $0.idx < $1.idx }
        return FinalTranscription(text: renderConversation(turns, timestamps: true), segments: turns, complete: true, issues: [])
    } catch is CancellationError { throw CancellationError() }
    catch {
        let provider = error as? ProviderError
        return FinalTranscription(text: "", segments: [], complete: false, issues: [TranscriptionIssue(source: .mic, spanID: url.lastPathComponent,
            userMessage: provider?.localizedDescription ?? "An audio section could not be transcribed. The recording is kept.",
            retryable: provider?.retryable ?? true, failureKind: provider?.failureKind ?? .unavailable)])
    }
}
