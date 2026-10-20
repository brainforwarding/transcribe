import Foundation
import AVFoundation

private struct MeetingRecoveryAudio: Codable {
    let source: Source
    let start: Double
    let end: Double
    let digest: String
}

/// Fill only unsealed audio intervals. Completed passages are never submitted to
/// another recognition or formatting pass, and every accepted response is durable
/// before the next provider request. No silence padding is treated as captured audio.
public func recoverMeetingTurns(tracks: [SessionAudioTrack], turns original: [MeetingTurn], directory: URL,
                                languages: [String] = [], keywords: [String] = [], config: OpenAIConfig,
                                session: URLSession = .shared,
                                onPersist: @escaping @Sendable ([MeetingTurn]) async throws -> Void) async throws -> [MeetingTurn] {
    var turns = planMeetingRecovery(tracks: tracks, turns: original)
    try Task.checkCancellation()
    try await onPersist(turns)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let cache = directory.appendingPathComponent("transcript-cache", isDirectory: true)
    for position in turns.indices where turns[position].state != .confirmed {
        try Task.checkCancellation()
        let turn = turns[position]
        do {
            let audio = directory.appendingPathComponent(turn.turnID + ".wav")
            let manifest = directory.appendingPathComponent(turn.turnID + ".json")
            let identity: MeetingRecoveryAudio
            if FileManager.default.fileExists(atPath: manifest.path) {
                identity = try JSONDecoder().decode(MeetingRecoveryAudio.self, from: Data(contentsOf: manifest))
                guard identity.source == turn.source, identity.start == turn.start, identity.end == turn.end,
                      try audioDigest(audio) == identity.digest else { throw ProviderError.cacheWrite }
            } else {
                guard let track = tracks.first(where: { $0.source == turn.source }) else { throw ProviderError.cacheWrite }
                // Confirm every sample belongs to a captured span before using the
                // existing renderer. Otherwise its padding would invent coverage.
                try validateCapturedMeetingInterval(track: track, start: turn.start, end: turn.end)
                let temporary = directory.appendingPathComponent(UUID().uuidString + ".wav")
                defer { try? FileManager.default.removeItem(at: temporary) }
                try writeAlignedAudio(tracks: [track], to: temporary, start: turn.start, duration: turn.end - turn.start, mix: false)
                identity = MeetingRecoveryAudio(source: turn.source, start: turn.start, end: turn.end, digest: try audioDigest(temporary))
                if FileManager.default.fileExists(atPath: audio.path) { try FileManager.default.removeItem(at: audio) }
                try FileManager.default.moveItem(at: temporary, to: audio)
                try JSONEncoder().encode(identity).write(to: manifest, options: .atomic)
            }
            let response = try await cachedAudioTranscript(fileURL: audio, model: .text, languages: languages,
                keywords: keywords, cacheDir: cache, prompt: nil, config: config, session: session,
                audioIdentity: identity.digest)
            try Task.checkCancellation()
            var next = turns
            next[position].text = response.text
            next[position].state = .confirmed; next[position].origin = .recovered; next[position].failureKind = nil
            try await onPersist(next)
            turns = next
        } catch is CancellationError { throw CancellationError() }
        catch let provider as ProviderError where provider == .cancelled { throw CancellationError() }
        catch {
            let failure = (error as? ProviderError)?.failureKind ?? .storage
            var next = turns
            next[position].state = .needsRecovery; next[position].failureKind = failure
            try await onPersist(next); turns = next
            if failure.allowsRecoveryAfterRemedy || failure == .invalidHints { break }
        }
    }
    return turns
}

func validateCapturedMeetingInterval(track: SessionAudioTrack, start: Double, end: Double) throws {
    guard start.isFinite, end.isFinite, end > start else { throw ProviderError.invalidResponse }
    var cursor = start
    for span in track.spans.sorted(by: { $0.offset < $1.offset }) where span.offset < end && span.offset + span.duration > start {
        guard span.offset <= cursor + 1 / 16_000 else { throw ProviderError.cacheWrite }
        let file = try AVAudioFile(forReading: span.url)
        guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1,
              Double(file.length) / 16_000 + 1 / 16_000 >= min(end, span.offset + span.duration) - span.offset
        else { throw ProviderError.cacheWrite }
        cursor = max(cursor, min(end, span.offset + span.duration))
    }
    guard cursor >= end - 1 / 16_000 else { throw ProviderError.cacheWrite }
}

public struct PipelineResult {
    public let transcriptURL: URL
    public let conversation: String
    public let hadSpeech: Bool
}
public struct SessionBody: Sendable {
    public let body: String
    public let conversation: String
    public let hadSpeech: Bool
}

/// Final results distinguish service failure from a successfully recognized empty recording.
/// Every successful response is atomically cached before processing another chunk.
private struct PreparedTrackManifest: Codable {
    let baseOffset: Double
    let chunks: [AudioChunk]
}

public func transcribeFinal(tracks: [SessionAudioTrack], kind: TranscriptionKind, chunkDir: URL,
                            languages: [String] = [], keywords: [String] = [], config: OpenAIConfig,
                            session: URLSession = .shared) async throws -> FinalTranscription {
    try FileManager.default.createDirectory(at: chunkDir, withIntermediateDirectories: true)
    let cache = chunkDir.appendingPathComponent("transcript-cache", isDirectory: true)
    var issues: [TranscriptionIssue] = []
    var turns: [Segment] = []
    var plain: [(Double, String)] = []
    guard !tracks.isEmpty else {
        return FinalTranscription(text: "", segments: [], complete: false,
            issues: [TranscriptionIssue(userMessage: "No captured audio is available.", retryable: false)])
    }
    for track in tracks.sorted(by: { $0.source < $1.source }) {
        try Task.checkCancellation()
        let spans = track.spans.sorted { $0.offset < $1.offset }
        guard !spans.isEmpty else {
            issues.append(TranscriptionIssue(source: track.source, userMessage: "An audio source did not capture any audio.", retryable: false))
            continue
        }
        guard spans.allSatisfy({ $0.offset.isFinite && $0.duration.isFinite && $0.offset >= 0 && $0.duration >= 0 }) else {
            issues.append(TranscriptionIssue(source: track.source, userMessage: "An audio timeline is invalid.", retryable: false)); continue
        }
        for pair in zip(spans, spans.dropFirst()) where pair.1.offset - (pair.0.offset + pair.0.duration) > 0.12 {
            issues.append(TranscriptionIssue(source: track.source, spanID: pair.1.id,
                userMessage: "A gap in recorded audio is preserved on the timeline.", retryable: false))
        }
        let sourceName = track.source == .mic ? "mic" : "system"
        let sourceDir = chunkDir.appendingPathComponent(sourceName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
            let manifestURL = sourceDir.appendingPathComponent("final-chunks.json")
            let prepared: PreparedTrackManifest
            if FileManager.default.fileExists(atPath: manifestURL.path) {
                prepared = try JSONDecoder().decode(PreparedTrackManifest.self, from: Data(contentsOf: manifestURL))
            } else {
            var normalized: [AudioSpan] = []
            for (i, span) in spans.enumerated() {
                let input = try AVAudioFile(forReading: span.url)
                if input.processingFormat.sampleRate == 16_000 && input.processingFormat.channelCount == 1 {
                    normalized.append(span)
                } else {
                    let convertedDir = sourceDir.appendingPathComponent("normalized-\(i)", isDirectory: true)
                    try FileManager.default.createDirectory(at: convertedDir, withIntermediateDirectories: true)
                    let parts = try segmentTrack(srcWAV: span.url, outDir: convertedDir, prefix: "input")
                    normalized.append(contentsOf: parts.map { AudioSpan(url: $0.url, offset: span.offset + $0.offset, duration: $0.duration) })
                }
            }
                let base = spans.first!.offset
                let end = spans.map { $0.offset + $0.duration }.max() ?? base
                let aligned = sourceDir.appendingPathComponent("aligned.wav")
                try writeAlignedAudio(tracks: [SessionAudioTrack(source: track.source, spans: normalized)],
                                      to: aligned, start: base, duration: max(0, end - base), mix: false)
                let encoded = try segmentTrack(srcWAV: aligned, outDir: sourceDir, prefix: "final")
                let stable = try encoded.map { chunk in
                    AudioChunk(url: chunk.url, offset: chunk.offset, duration: chunk.duration,
                               digest: try audioDigest(chunk.url))
                }
                prepared = PreparedTrackManifest(baseOffset: base, chunks: stable)
                try JSONEncoder().encode(prepared).write(to: manifestURL, options: .atomic)
            }
            let base = prepared.baseOffset
            let chunks = prepared.chunks
            guard !chunks.isEmpty else {
                issues.append(TranscriptionIssue(source: track.source, userMessage: "The recorded audio is empty.", retryable: false)); continue
            }
            for (chunkIndex, chunk) in chunks.enumerated() {
                try Task.checkCancellation()
                do {
                    let response = try await cachedAudioTranscript(fileURL: chunk.url,
                        model: kind == .dictation ? .text : .diarized,
                        languages: languages, keywords: kind == .dictation ? keywords : [],
                        cacheDir: cache, prompt: nil,
                        config: config, session: session,
                        audioIdentity: chunk.digest, maximumDuration: chunk.duration)
                    let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if kind == .dictation {
                        if !text.isEmpty { plain.append((base + chunk.offset, text)) }
                    } else {
                        let label = track.source == .system ? "System audio" : (kind == .inPersonMeeting ? "Microphone" : "You")
                        for (turnIndex, turn) in response.segments.enumerated() {
                            let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !text.isEmpty else { continue }
                            guard turn.end <= chunk.duration + 1 else { throw ProviderError.invalidResponse }
                            turns.append(Segment(start: base + chunk.offset + turn.start, end: base + chunk.offset + turn.end,
                                                 label: label, text: text, source: track.source,
                                                 idx: track.source.rawValue * 1_000_000_000 + chunkIndex * 100_000 + turnIndex))
                        }
                    }
                } catch is CancellationError { throw CancellationError() }
                catch {
                    let provider = error as? ProviderError
                    issues.append(TranscriptionIssue(source: track.source, spanID: chunk.url.lastPathComponent,
                        userMessage: provider?.localizedDescription ?? "An audio section could not be transcribed. The recording is kept.",
                        retryable: provider?.retryable ?? true, failureKind: provider?.failureKind ?? .unavailable))
                    if provider == .authentication || provider == .accessDenied || provider == .quota || provider == .insufficientCredits || provider == .billingLimit { break }
                }
            }
        } catch is CancellationError { throw CancellationError() }
        catch {
            issues.append(TranscriptionIssue(source: track.source,
                userMessage: "A captured audio source could not be read. The recording is kept.", retryable: true, failureKind: .storage))
        }
    }
    turns.sort { a, b in
        if a.start != b.start { return a.start < b.start }
        if a.source != b.source { return a.source < b.source }
        return a.idx < b.idx
    }
    let text = kind == .dictation ? plain.sorted { $0.0 < $1.0 }.map(\.1).joined(separator: "\n\n")
                                  : renderConversation(turns, timestamps: true)
    return FinalTranscription(text: text, segments: turns, complete: issues.isEmpty, issues: issues)
}

public func transcribePreview(window: PreviewWindow, languages: [String] = [], keywords: [String] = [],
                              config: OpenAIConfig, session: URLSession = .shared) async throws -> String {
    // Finalized WAV window is only 2.9 MB; the raw capture spans remain separate.
    let response = try await requestAudioTranscript(fileURL: window.url, model: .text,
                                                    languages: languages, keywords: keywords, config: config, session: session)
    return response.text.trimmingCharacters(in: .whitespacesAndNewlines)
}

public func transcribeSessionBody(micWAV: URL?, systemWAV: URL?, chunkDir: URL, language: String?, micOffset: Double,
                                  meLabel: String = "You", themLabel: String = "Them", labelSpeakers: Bool = true,
                                  includeSummary: Bool = false, summaryModel: String = "gpt-4o", config: OpenAIConfig) async throws -> SessionBody {
    var tracks: [SessionAudioTrack] = []
    for (source, url, offset) in [(Source.mic, micWAV, micOffset), (.system, systemWAV, 0.0)] {
        guard let url else { continue }
        let file = try AVAudioFile(forReading: url)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        tracks.append(SessionAudioTrack(source: source, spans: [AudioSpan(url: url, offset: offset, duration: duration)]))
    }
    let result = try await transcribeFinal(tracks: tracks, kind: labelSpeakers ? .onlineMeeting : .dictation,
                                          chunkDir: chunkDir, languages: language.map { [$0] } ?? [], config: config)
    guard result.complete else { throw RuntimeError("Transcription is incomplete. Retain the audio and retry missing sections.") }
    var conversation = result.text
    if labelSpeakers {
        let labeled = result.segments.map { turn -> Segment in
            var turn = turn; turn.label = turn.source == .mic ? meLabel : themLabel; return turn
        }
        conversation = renderConversation(mergeSegments(labeled), timestamps: true)
    }
    var body = conversation.isEmpty ? "_(no speech detected)_\n" : conversation + "\n"
    if includeSummary, !conversation.isEmpty, let summary = await summarize(conversation, model: summaryModel, config: config) {
        body = "## Summary\n\n\(summary)\n\n## Transcript\n\n\(conversation)\n"
    }
    return SessionBody(body: body, conversation: conversation, hadSpeech: !conversation.isEmpty)
}

public func transcribeSession(micWAV: URL?, systemWAV: URL?, chunkDir: URL, transcriptURL: URL, title: String,
                              language: String?, micOffset: Double, meLabel: String = "You", themLabel: String = "Them",
                              labelSpeakers: Bool = true, includeSummary: Bool = false,
                              summaryModel: String = "gpt-4o", config: OpenAIConfig) async throws -> PipelineResult {
    let result = try await transcribeSessionBody(micWAV: micWAV, systemWAV: systemWAV, chunkDir: chunkDir,
        language: language, micOffset: micOffset, meLabel: meLabel, themLabel: themLabel,
        labelSpeakers: labelSpeakers, includeSummary: includeSummary, summaryModel: summaryModel, config: config)
    try FileManager.default.createDirectory(at: transcriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try ("# \(title)\n\n" + result.body).write(to: transcriptURL, atomically: true, encoding: .utf8)
    return PipelineResult(transcriptURL: transcriptURL, conversation: result.conversation, hadSpeech: result.hadSpeech)
}
