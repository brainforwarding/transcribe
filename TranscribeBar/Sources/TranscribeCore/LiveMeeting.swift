import Foundation

public struct MeetingTurn: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case pending, confirmed, needsRecovery }
    public enum Origin: String, Codable, Sendable { case live, recovered }
    public enum EndReason: String, Codable, Sendable { case pause, forced, stopped, discontinuity }
    public var idx: Int
    public var source: Source
    public var start: Double
    public var end: Double
    public var state: State
    public var origin: Origin
    public var text: String
    public var failureKind: ServiceFailureKind?
    public var endReason: EndReason?
    public var turnID: String { "turn-\(idx)" }
    public init(idx: Int, source: Source, start: Double, end: Double, state: State = .pending,
                origin: Origin = .live, text: String = "", failureKind: ServiceFailureKind? = nil,
                endReason: EndReason? = nil) {
        self.idx = idx; self.source = source; self.start = start; self.end = end; self.state = state
        self.origin = origin; self.text = text; self.failureKind = failureKind
        self.endReason = endReason
    }
}

public struct MeetingAudioInterval: Sendable, Equatable {
    public let source: Source
    public let start: Double
    public let end: Double
    public init(source: Source, start: Double, end: Double) { self.source = source; self.start = start; self.end = end }
}

public struct LiveMeetingDraft: Sendable, Equatable, Identifiable {
    public var id: String { "\(source.rawValue)-\(itemID)" }
    public let source: Source
    public let itemID: String
    public let text: String
    public init(source: Source, itemID: String, text: String) { self.source = source; self.itemID = itemID; self.text = text }
}

/// Captured samples minus sealed coverage. Tiny frame-rounding tolerances are not
/// extended across actual host-clock gaps. Pending intervals count only when asked.
public func uncoveredMeetingAudio(tracks: [SessionAudioTrack], turns: [MeetingTurn],
                                   includePending: Bool) -> [MeetingAudioInterval] {
    let epsilon = 1.0 / 16_000
    var output: [MeetingAudioInterval] = []
    for track in tracks {
        let covered = turns.filter {
            $0.source == track.source && (includePending || $0.state == .confirmed)
                && $0.start.isFinite && $0.end.isFinite && $0.end > $0.start
        }.sorted { $0.start < $1.start }
        for span in track.spans.sorted(by: { $0.offset < $1.offset }) {
            guard span.offset.isFinite, span.duration.isFinite, span.offset >= 0, span.duration > 0 else { continue }
            var cursor = span.offset
            let end = span.offset + span.duration
            for seal in covered where seal.end > cursor && seal.start < end {
                if seal.start > cursor + epsilon { output.append(.init(source: track.source, start: cursor, end: min(end, seal.start))) }
                cursor = max(cursor, min(end, seal.end))
            }
            if end > cursor + epsilon { output.append(.init(source: track.source, start: cursor, end: end)) }
        }
    }
    return output.sorted { $0.source != $1.source ? $0.source < $1.source : $0.start < $1.start }
}

/// Coalesce only new, never-submitted captured coverage before assigning retry IDs.
/// Existing committed IDs/ranges remain separate even after a connection failure.
public func planMeetingRecovery(tracks: [SessionAudioTrack], turns: [MeetingTurn],
                                maximumInterval: Double = 300) -> [MeetingTurn] {
    // Five minutes of canonical float WAV is ~19.2 MB, under the 24 MB
    // upload guard, while keeping an extended outage below the Team request cap.
    let maximum = max(1, min(300, maximumInterval))
    var merged: [MeetingAudioInterval] = []
    for interval in uncoveredMeetingAudio(tracks: tracks, turns: turns, includePending: true) {
        if let last = merged.last, last.source == interval.source, abs(last.end - interval.start) <= 1 / 16_000 {
            merged[merged.count - 1] = .init(source: last.source, start: last.start, end: interval.end)
        } else { merged.append(interval) }
    }
    var result = turns.map { turn -> MeetingTurn in
        var turn = turn
        if turn.state == .pending { turn.state = .needsRecovery }
        return turn
    }
    for interval in merged {
        var start = interval.start
        while start < interval.end - 1 / 16_000 {
            let end = min(interval.end, start + maximum)
            let idx = nextMeetingIndex(source: interval.source, turns: result)
            result.append(.init(idx: idx, source: interval.source, start: start, end: end,
                                state: .needsRecovery, origin: .recovered))
            start = end
        }
    }
    return result
}

func nextMeetingIndex(source: Source, turns: [MeetingTurn]) -> Int {
    let base = source.rawValue * 1_000_000_000
    return max(base - 1, turns.filter { $0.source == source }.map(\.idx).max() ?? (base - 1)) + 1
}

extension SessionRecord {
    /// Validate an entire snapshot before atomically saving it. A completed turn
    /// can never change text, range, source, or ID, including an empty completion.
    public mutating func applyMeetingTurns(_ proposed: [MeetingTurn]) throws {
        guard usesLiveTranscription, Set(proposed.map(\.idx)).count == proposed.count,
              proposed.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start
                  && $0.idx >= $0.source.rawValue * 1_000_000_000
                  && $0.idx < ($0.source.rawValue + 1) * 1_000_000_000 }) else { throw ProviderError.invalidResponse }
        let byID = Dictionary(uniqueKeysWithValues: proposed.map { ($0.idx, $0) })
        for old in meetingTurns {
            guard let new = byID[old.idx], old.source == new.source, old.start == new.start, old.end == new.end else {
                throw ProviderError.invalidResponse
            }
            if old.state == .confirmed && old != new { throw ProviderError.invalidResponse }
        }
        let oldConfirmed = Set(meetingTurns.filter { $0.state == .confirmed }.map(\.idx))
        transcriptRevision += proposed.filter { $0.state == .confirmed && !oldConfirmed.contains($0.idx) }.count
        meetingTurns = proposed
        segments = proposed.filter { $0.state == .confirmed && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { Segment(start: $0.start, end: $0.end,
                label: $0.source == .system ? "System audio" : (meetingMode == .inPerson ? "Microphone" : "You"),
                text: $0.text, source: $0.source, idx: $0.idx, timing: .audioInterval) }
            .sorted { a, b in a.start != b.start ? a.start < b.start : (a.source != b.source ? a.source < b.source : a.idx < b.idx) }
        if kind == .dictation {
            transcript = dictationBoundaryResult.flatMap { $0.turns == proposed ? $0.text : nil }
                ?? segments.map(\.text).joined(separator: " ")
            rawTranscript = transcript
        } else { transcript = renderConversation(segments, timestamps: true) }
    }

    public var liveMeetingIssues: [TranscriptionIssue] {
        meetingTurns.filter { $0.state == .needsRecovery }.map {
            TranscriptionIssue(source: $0.source, spanID: $0.turnID,
                userMessage: kind == .dictation ? "Some dictated words are missing. The saved audio can be retried."
                    : "Some meeting words are missing. The saved audio can be retried.",
                failureKind: $0.failureKind ?? .unavailable)
        }
    }

    public var hasSealedMeetingAudio: Bool {
        !usesLiveTranscription || uncoveredMeetingAudio(tracks: tracks, turns: meetingTurns, includePending: false).isEmpty
    }
}
