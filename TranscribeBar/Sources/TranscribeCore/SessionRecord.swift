import Foundation

public enum SessionKind: String, Codable, Sendable { case dictation, meeting }
public enum MeetingMode: String, Codable, Sendable, CaseIterable { case online, inPerson }
public enum SessionStatus: String, Codable, Sendable {
    case starting, recording, processing, complete, partial, cancelled, failed
    public var interrupted: Bool { self == .starting || self == .recording || self == .processing }
}
public enum DeliveryState: String, Codable, Sendable { case never, eligible, ready, inserted, cancelled }
public enum SummaryStatus: String, Codable, Sendable { case none, processing, complete, failed }

/// Durable user content. Audio stays inside this record's owned directory until a
/// complete transcript has been saved. Historical recovery never enables insertion.
public struct SessionRecord: Identifiable, Codable, Sendable {
    public var id: UUID
    public var kind: SessionKind
    public var meetingMode: MeetingMode
    public var title: String
    public var startedAt: Date
    public var duration: Double
    public var status: SessionStatus
    public var delivery: DeliveryState
    public var notes: String
    public var preview: String
    public var transcript: String
    public var rawTranscript: String?
    public var formattingFailure: ServiceFailureKind?
    public var serviceProviderID: String?
    public var segments: [Segment]
    public var summary: String
    public var summaryStatus: SummaryStatus
    public var summaryEvidenceIDs: [String]
    public var summaryEvidence: [NoteEvidence]
    public var summaryNotesSnapshot: String
    public var issues: [String]
    public var transcriptionIssues: [TranscriptionIssue]
    public var tracks: [SessionAudioTrack]
    public var captureIncomplete: Bool
    public var exportURL: URL?
    public var importURL: URL?
    public var imported: Bool
    public var language: String?
    public var keywords: [String]

    public init(id: UUID = UUID(), kind: SessionKind, meetingMode: MeetingMode = .online,
                title: String, startedAt: Date = Date(), language: String? = nil,
                keywords: [String] = []) {
        self.id = id; self.kind = kind; self.meetingMode = meetingMode
        self.title = title; self.startedAt = startedAt; self.language = language
        self.keywords = keywords; duration = 0; status = .starting
        delivery = kind == .dictation ? .eligible : .never
        notes = ""; preview = ""; transcript = ""; rawTranscript = nil; formattingFailure = nil; serviceProviderID = nil; segments = []
        summary = ""; summaryStatus = .none; summaryEvidenceIDs = []; summaryEvidence = []; summaryNotesSnapshot = ""
        issues = []; transcriptionIssues = []; tracks = []; captureIncomplete = false
        exportURL = nil; importURL = nil; imported = false
    }

    public var canRecover: Bool {
        let hasAudio = tracks.contains { !$0.spans.isEmpty }
        if status == .partial { return hasAudio && transcriptionIssues.contains { $0.retryable || $0.failureKind?.allowsRecoveryAfterRemedy == true } }
        return hasAudio && (status == .failed || status == .cancelled)
    }
    public var isPartial: Bool { status == .partial || captureIncomplete }
    public var hasText: Bool { !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private enum CodingKeys: String, CodingKey {
        case id, kind, meetingMode, title, startedAt, duration, status, delivery, notes, preview, transcript, rawTranscript, formattingFailure, serviceProviderID,
             segments, summary, summaryStatus, summaryEvidenceIDs, summaryEvidence, summaryNotesSnapshot,
             issues, transcriptionIssues, tracks, captureIncomplete, exportURL, importURL, imported, language, keywords
    }
    public init(from decoder: Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try v.decode(UUID.self, forKey: .id), kind: try v.decode(SessionKind.self, forKey: .kind),
                  meetingMode: try v.decodeIfPresent(MeetingMode.self, forKey: .meetingMode) ?? .online,
                  title: try v.decode(String.self, forKey: .title),
                  startedAt: try v.decode(Date.self, forKey: .startedAt),
                  language: try v.decodeIfPresent(String.self, forKey: .language),
                  keywords: try v.decodeIfPresent([String].self, forKey: .keywords) ?? [])
        duration = try v.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        status = try v.decodeIfPresent(SessionStatus.self, forKey: .status) ?? .failed
        delivery = try v.decodeIfPresent(DeliveryState.self, forKey: .delivery) ?? .ready
        notes = try v.decodeIfPresent(String.self, forKey: .notes) ?? ""
        preview = try v.decodeIfPresent(String.self, forKey: .preview) ?? ""
        transcript = try v.decodeIfPresent(String.self, forKey: .transcript) ?? ""
        rawTranscript = try v.decodeIfPresent(String.self, forKey: .rawTranscript)
        formattingFailure = try v.decodeIfPresent(ServiceFailureKind.self, forKey: .formattingFailure)
        serviceProviderID = try v.decodeIfPresent(String.self, forKey: .serviceProviderID)
        segments = try v.decodeIfPresent([Segment].self, forKey: .segments) ?? []
        summary = try v.decodeIfPresent(String.self, forKey: .summary) ?? ""
        summaryStatus = try v.decodeIfPresent(SummaryStatus.self, forKey: .summaryStatus) ?? .none
        summaryEvidenceIDs = try v.decodeIfPresent([String].self, forKey: .summaryEvidenceIDs) ?? []
        summaryEvidence = try v.decodeIfPresent([NoteEvidence].self, forKey: .summaryEvidence) ?? []
        summaryNotesSnapshot = try v.decodeIfPresent(String.self, forKey: .summaryNotesSnapshot) ?? notes
        issues = try v.decodeIfPresent([String].self, forKey: .issues) ?? []
        transcriptionIssues = try v.decodeIfPresent([TranscriptionIssue].self, forKey: .transcriptionIssues) ?? []
        tracks = try v.decodeIfPresent([SessionAudioTrack].self, forKey: .tracks) ?? []
        captureIncomplete = try v.decodeIfPresent(Bool.self, forKey: .captureIncomplete) ?? false
        exportURL = try v.decodeIfPresent(URL.self, forKey: .exportURL)
        imported = try v.decodeIfPresent(Bool.self, forKey: .imported) ?? false
        importURL = try v.decodeIfPresent(URL.self, forKey: .importURL) ?? (imported ? exportURL : nil)
    }
}
