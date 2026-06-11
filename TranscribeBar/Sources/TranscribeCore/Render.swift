import Foundation

/// `[mm:ss]` with round-half-to-even, matching Python's `round()` (banker's rounding)
/// in meetrec.py `_mmss`.
public func mmss(_ t: Double) -> String {
    let s = max(0, Int(t.rounded(.toNearestOrEven)))
    return String(format: "%02d:%02d", s / 60, s % 60)
}

/// Port of meetrec.py `render_conversation`.
public func renderConversation(_ blocks: [Segment], timestamps: Bool = true) -> String {
    blocks.map { b in
        let prefix = timestamps ? "[\(mmss(b.start))] " : ""
        return "\(prefix)**\(b.label):** \(b.text)"
    }.joined(separator: "\n\n")
}

/// Single-track (mic-only) render: no speaker labels, no timestamps — plain flowing
/// paragraphs, one per merged block (mergeSegments splits blocks on >1.5 s pauses).
public func renderPlain(_ blocks: [Segment]) -> String {
    blocks.map(\.text).joined(separator: "\n\n")
}

/// Port of meetrec.py `render_appendix`: verbatim per-track text (ground truth).
public func renderAppendix(_ tracks: [(heading: String, segments: [Segment])]) -> String {
    tracks.map { heading, segs in
        let body = segs.map { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "### \(heading)\n\n\(body.isEmpty ? "_(no speech detected)_" : body)"
    }.joined(separator: "\n\n")
}
