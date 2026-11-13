import Foundation
import CoreGraphics

enum AdditionalShortcut: String, CaseIterable {
    case controlOptionSpace, controlShiftSpace, off

    var title: String {
        switch self {
        case .controlOptionSpace: return "⌃ ⌥ Space"
        case .controlShiftSpace: return "⌃ ⇧ Space"
        case .off: return "Off"
        }
    }

    func matches(code: UInt16, flags: CGEventFlags) -> Bool {
        guard code == 49, self != .off else { return false }
        let relevant: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]
        let expected: CGEventFlags = self == .controlOptionSpace ? [.maskControl, .maskAlternate] : [.maskControl, .maskShift]
        return flags.intersection(relevant) == expected
    }
}
