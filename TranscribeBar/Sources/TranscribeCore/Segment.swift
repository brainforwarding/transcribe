import Foundation

/// Which physical track a segment came from. The raw value is the merge tiebreak
/// rank — mic (0) sorts before system (1) at equal start times, matching the Python
/// `merge_segments` which sorts the ASCII strings "mic" < "system".
public enum Source: Int, Sendable, Comparable {
    case mic = 0
    case system = 1
    public static func < (a: Source, b: Source) -> Bool { a.rawValue < b.rawValue }
}

/// One transcribed span on the global (shared) timeline. `idx` is an input-order
/// tiebreak: Swift's sort is NOT stable, so we carry the original concatenation order
/// (mic segments first, then system) to reproduce the tested Python output exactly.
public struct Segment: Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var label: String
    public var text: String
    public var source: Source
    public var idx: Int

    public init(start: Double, end: Double, label: String, text: String,
                source: Source, idx: Int = 0) {
        self.start = start
        self.end = end
        self.label = label
        self.text = text
        self.source = source
        self.idx = idx
    }
}
