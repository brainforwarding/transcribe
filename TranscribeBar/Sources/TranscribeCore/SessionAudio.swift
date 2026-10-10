import Foundation

public struct AudioSpan: Codable, Sendable, Equatable {
    public var url: URL
    public var offset: Double
    public var duration: Double
    public var id: String { url.lastPathComponent }
    public init(url: URL, offset: Double, duration: Double) {
        self.url = url; self.offset = offset; self.duration = duration
    }
}

public struct SessionAudioTrack: Codable, Sendable, Equatable {
    public var source: Source
    public var spans: [AudioSpan]
    public init(source: Source, spans: [AudioSpan]) { self.source = source; self.spans = spans }
}

public enum CaptureHealthState: String, Codable, Sendable {
    case starting, active, silent, interrupted, unavailable
}

public struct CaptureHealth: Codable, Sendable {
    public let source: Source
    public let state: CaptureHealthState
    public let message: String?
    public init(source: Source, state: CaptureHealthState, message: String? = nil) {
        self.source = source; self.state = state; self.message = message
    }
}

public struct PreviewWindow: Codable, Sendable {
    public let url: URL
    public let offset: Double
    public let duration: Double
    public init(url: URL, offset: Double, duration: Double) {
        self.url = url; self.offset = offset; self.duration = duration
    }
}

public struct TranscriptionIssue: Codable, Sendable, Equatable {
    public let source: Source?
    public let spanID: String?
    public let userMessage: String
    public let retryable: Bool
    public init(source: Source? = nil, spanID: String? = nil, userMessage: String, retryable: Bool = true) {
        self.source = source; self.spanID = spanID; self.userMessage = userMessage; self.retryable = retryable
    }
}

public enum TranscriptionKind: String, Codable, Sendable {
    case dictation, onlineMeeting, inPersonMeeting
}

public struct FinalTranscription: Codable, Sendable {
    public let text: String
    public let segments: [Segment]
    public let complete: Bool
    public let issues: [TranscriptionIssue]
    public init(text: String, segments: [Segment], complete: Bool, issues: [TranscriptionIssue]) {
        self.text = text; self.segments = segments; self.complete = complete; self.issues = issues
    }
}

public struct NoteEvidence: Codable, Sendable {
    public let id: String
    public let text: String
    public let turnIDs: [String]
    public init(id: String, text: String, turnIDs: [String]) { self.id = id; self.text = text; self.turnIDs = turnIDs }
}

public struct GeneratedNotes: Codable, Sendable {
    public let text: String
    public let evidence: [NoteEvidence]
    public init(text: String, evidence: [NoteEvidence]) { self.text = text; self.evidence = evidence }
}
