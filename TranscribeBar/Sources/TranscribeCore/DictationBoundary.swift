import Foundation

/// Decode evidence from the retired audio-recheck experiment. New dictation uses
/// one chunk assembly prompt; these historical results are never recomputed.
public struct DictationBoundaryResult: Codable, Sendable, Equatable {
    public let turns: [MeetingTurn]
    public let text: String
    public let checkedJoins: Int
    public let recheckedGroups: Int
    public init(turns: [MeetingTurn], text: String, checkedJoins: Int, recheckedGroups: Int) {
        self.turns = turns; self.text = text; self.checkedJoins = checkedJoins; self.recheckedGroups = recheckedGroups
    }
}

