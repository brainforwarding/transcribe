import Foundation

public struct PipelineResult {
    public let transcriptURL: URL
    public let conversation: String
    public let hadSpeech: Bool
}

/// Everything below the transcript's H1: the rendered conversation (plus the optional
/// Summary section), ready for the caller to prepend `# <title>\n\n` and write out.
public struct SessionBody: Sendable {
    public let body: String          // markdown below the H1, ends with "\n"
    public let conversation: String
    public let hadSpeech: Bool
}

/// The transcription work without the final file write: segment each track, transcribe with
/// whisper-1, merge on the shared timeline, render. Splitting this from `transcribeSession`
/// lets the app start transcribing immediately and decide the title/filename afterwards
/// (the stop-time title prompt). `labelSpeakers: false` is mic-only mode — a single track
/// rendered as plain paragraphs, no You/Them labels, no timestamps.
public func transcribeSessionBody(micWAV: URL?, systemWAV: URL?,
                                  chunkDir: URL, language: String?, micOffset: Double,
                                  meLabel: String = "You", themLabel: String = "Them",
                                  labelSpeakers: Bool = true,
                                  includeSummary: Bool = false, summaryModel: String = "gpt-4o",
                                  config: OpenAIConfig) async throws -> SessionBody {
    try FileManager.default.createDirectory(at: chunkDir, withIntermediateDirectories: true)

    var idx = 0
    var micSegs: [Segment] = []
    var sysSegs: [Segment] = []

    if let micWAV, FileManager.default.fileExists(atPath: micWAV.path) {
        let chunks = try await segmentTrack(srcWAV: micWAV, outDir: chunkDir, prefix: "mic")
        let r = await transcribeTrack(chunks: chunks.map { ($0.url, $0.offset) },
                                      baseOffset: micOffset, label: meLabel, source: .mic,
                                      language: language, config: config, startIdx: idx)
        micSegs = r.segments
        idx = r.nextIdx
    }
    if let systemWAV, FileManager.default.fileExists(atPath: systemWAV.path) {
        let chunks = try await segmentTrack(srcWAV: systemWAV, outDir: chunkDir, prefix: "sys")
        let r = await transcribeTrack(chunks: chunks.map { ($0.url, $0.offset) },
                                      baseOffset: 0, label: themLabel, source: .system,
                                      language: language, config: config, startIdx: idx)
        sysSegs = r.segments
        idx = r.nextIdx
    }

    let blocks = mergeSegments(micSegs + sysSegs)
    let conversation = labelSpeakers ? renderConversation(blocks, timestamps: true)
                                     : renderPlain(blocks)

    var body: String
    if includeSummary, !conversation.isEmpty,
       let s = await summarize(labelSpeakers ? renderConversation(blocks, timestamps: false) : conversation,
                               model: summaryModel, config: config) {
        let heading = labelSpeakers ? "Conversation" : "Transcript"
        body = "## Summary\n\n\(s)\n\n## \(heading)\n\n\(conversation)\n"
    } else {
        body = (conversation.isEmpty ? "_(no speech detected)_" : conversation) + "\n"
    }
    return SessionBody(body: body, conversation: conversation, hadSpeech: !blocks.isEmpty)
}

/// Segment each track, transcribe with whisper-1, merge on the shared timeline, and write a
/// single `<title>.md` (just the Conversation; optional Summary). No appendix.
/// `chunkDir` is a working directory for the intermediate audio chunks; `transcriptURL` is
/// the final markdown file (e.g. `~/Documents/Transcribe/2026-06-05_21-52-17.md`).
public func transcribeSession(micWAV: URL?, systemWAV: URL?,
                              chunkDir: URL, transcriptURL: URL, title: String,
                              language: String?, micOffset: Double,
                              meLabel: String = "You", themLabel: String = "Them",
                              labelSpeakers: Bool = true,
                              includeSummary: Bool = false, summaryModel: String = "gpt-4o",
                              config: OpenAIConfig) async throws -> PipelineResult {
    let r = try await transcribeSessionBody(
        micWAV: micWAV, systemWAV: systemWAV, chunkDir: chunkDir,
        language: language, micOffset: micOffset, meLabel: meLabel, themLabel: themLabel,
        labelSpeakers: labelSpeakers, includeSummary: includeSummary,
        summaryModel: summaryModel, config: config)

    let md = "# \(title)\n\n" + r.body
    try FileManager.default.createDirectory(at: transcriptURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try md.write(to: transcriptURL, atomically: true, encoding: .utf8)
    return PipelineResult(transcriptURL: transcriptURL, conversation: r.conversation,
                          hadSpeech: r.hadSpeech)
}
