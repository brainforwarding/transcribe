import Foundation

/// Deterministic, network-free checks mirroring meetrec.py's merge_segments tests, plus the
/// panel's must-test cases (unstable-sort tie, equal-start mic-before-system, inclusive 1.5 s
/// boundary, banker's rounding). Returns the list of failures (empty = all passed).
public func mergeSelftest() -> [String] {
    var failures: [String] = []
    func check(_ name: String, _ cond: Bool) { if !cond { failures.append(name) } }
    func seg(_ s: Double, _ e: Double, _ label: String, _ text: String,
             _ source: Source, _ idx: Int = 0) -> Segment {
        Segment(start: s, end: e, label: label, text: text, source: source, idx: idx)
    }

    // 1. adjacency coalesce + chronology
    let b1 = mergeSegments([
        seg(0.0, 2.0, "You", "hello there", .mic, 0),
        seg(2.3, 2.9, "You", "how are you", .mic, 1),
        seg(3.0, 4.0, "Them", "good thanks", .system, 2),
        seg(4.2, 5.0, "You", "great", .mic, 3),
    ])
    check("1.labels", b1.map(\.label) == ["You", "Them", "You"])
    check("1.coalesceText", b1.first?.text == "hello there how are you")
    check("1.thirdText", b1.count == 3 && b1[2].text == "great")

    // 2. interleave by start across tracks
    let b2 = mergeSegments([
        seg(5.0, 6.0, "Them", "second", .system, 0),
        seg(0.5, 1.0, "You", "first", .mic, 1),
        seg(10.0, 11.0, "You", "third", .mic, 2),
    ])
    check("2.order", b2.map(\.text) == ["first", "second", "third"])

    // 3. gap threshold inclusive
    check("3.gapTooBig", mergeSegments([
        seg(0, 1, "You", "a", .mic, 0), seg(3.0, 4, "You", "b", .mic, 1),
    ]).count == 2)
    check("3.gapExact", mergeSegments([
        seg(0, 1, "You", "a", .mic, 0), seg(2.5, 4, "You", "b", .mic, 1),
    ]).count == 1)

    // 4. empty dropped + clamp
    let b4 = mergeSegments([
        seg(0, 1, "You", "   ", .mic, 0),
        seg(1, 0.5, "Them", "x", .system, 1),
    ])
    check("4.emptyDropped", b4.count == 1 && b4[0].label == "Them")
    check("4.clamp", (b4.first?.end ?? -1) >= (b4.first?.start ?? 0))

    // 5. equal start: mic before system
    let b5 = mergeSegments([
        seg(1.0, 2.0, "Them", "them", .system, 0),
        seg(1.0, 2.0, "You", "you", .mic, 1),
    ])
    check("5.micFirst", b5.map(\.text) == ["you", "them"])

    // 6. idx tiebreak (Swift sort is not stable)
    let b6 = mergeSegments([
        seg(0.0, 0.0, "You", "alpha", .mic, 0),
        seg(0.0, 0.0, "You", "beta", .mic, 1),
        seg(0.0, 0.0, "You", "gamma", .mic, 2),
    ])
    check("6.tiebreak", b6.count == 1 && b6[0].text == "alpha beta gamma")

    // 7. render + banker's rounding
    check("7.mmss125", mmss(125.0) == "02:05")
    check("7.mmssEven", mmss(30.5) == "00:30")
    check("7.mmssOdd", mmss(31.5) == "00:32")
    check("7.renderTs", renderConversation([seg(0, 1, "You", "first", .mic)], timestamps: true)
          == "[00:00] **You:** first")
    check("7.renderNoTs", renderConversation([seg(5, 6, "Them", "x", .system)], timestamps: false)
          == "**Them:** x")

    // 8. mic-only render: plain paragraphs, no labels, no timestamps
    check("8.plain", renderPlain([seg(0, 1, "You", "first thought.", .mic, 0),
                                  seg(3, 4, "You", "second thought.", .mic, 1)])
          == "first thought.\n\nsecond thought.")
    check("8.plainEmpty", renderPlain([]) == "")

    return failures
}

/// Deterministic checks for the title→filename helpers (slug, stem, collision suffix).
/// Pure functions, no filesystem. Returns the list of failures (empty = all passed).
public func namingSelftest() -> [String] {
    var failures: [String] = []
    func check(_ name: String, _ cond: Bool) { if !cond { failures.append(name) } }

    // slugify: lowercase, accents folded, specials collapsed to single hyphens, trimmed
    check("s.basic", slugify("Weekly sync") == "weekly-sync")
    check("s.accents", slugify("Reunión de diseño — café") == "reunion-de-diseno-cafe")
    check("s.punct", slugify("  Hello,,,   World!! ") == "hello-world")
    check("s.digits", slugify("Q3 2026 planning") == "q3-2026-planning")
    check("s.nothingLeft", slugify("¿¿??") == "")
    check("s.maxLen", slugify(String(repeating: "a", count: 100), maxLength: 10) == "aaaaaaaaaa")
    check("s.maxLenNoTrailingHyphen", slugify("aaa bbb", maxLength: 4) == "aaa")

    // transcriptStem: date + slug with a usable title, the bare stamp otherwise
    let stamp = "2026-06-11_09-30-00"
    check("n.titled", transcriptStem(stamp: stamp, title: "Voice note") == "2026-06-11-voice-note")
    check("n.untitled", transcriptStem(stamp: stamp, title: nil) == stamp)
    check("n.unusableTitle", transcriptStem(stamp: stamp, title: "!!!") == stamp)

    // availableTranscriptURL: -2, -3, … on collision
    let dir = URL(fileURLWithPath: "/tmp/transcribe-selftest", isDirectory: true)
    let taken: Set<String> = ["a.md", "a-2.md"]
    check("n.free", availableTranscriptURL(in: dir, stem: "b") { taken.contains($0.lastPathComponent) }
          .lastPathComponent == "b.md")
    check("n.collision", availableTranscriptURL(in: dir, stem: "a") { taken.contains($0.lastPathComponent) }
          .lastPathComponent == "a-3.md")

    return failures
}
