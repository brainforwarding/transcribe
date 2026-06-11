import Foundation

/// Same-speaker segments closer than this (seconds) are coalesced. Mirrors
/// meetrec.py COALESCE_GAP. Constant, not a setting.
public let coalesceGap: Double = 1.5

/// Pure port of meetrec.py `merge_segments`: drop empties, clamp non-monotonic, sort on
/// the global clock, then coalesce SORTED-ADJACENT same-label segments (an interposed
/// other-speaker segment breaks the run, so chronology is preserved). Returns ordered blocks.
public func mergeSegments(_ input: [Segment], gap: Double = coalesceGap) -> [Segment] {
    var segs = input.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    for i in segs.indices where segs[i].end < segs[i].start {
        segs[i].end = segs[i].start
    }
    // Stable, total ordering: (start, source, end, idx). The idx tiebreak makes this
    // deterministic despite Swift's non-stable sort.
    segs.sort { a, b in
        if a.start != b.start { return a.start < b.start }
        if a.source != b.source { return a.source < b.source }
        if a.end != b.end { return a.end < b.end }
        return a.idx < b.idx
    }

    var blocks: [Segment] = []
    for s in segs {
        if var last = blocks.last,
           last.label == s.label,
           (s.start - last.end) <= gap {
            last.end = max(last.end, s.end)
            last.text = (last.text + " " + s.text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            blocks[blocks.count - 1] = last
        } else {
            blocks.append(s)
        }
    }
    return blocks
}
