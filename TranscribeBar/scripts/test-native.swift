import Foundation
import CoreGraphics

@main
struct NativeSelftest {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }

    static func main() {
        var taps = OptionTapRecognizer()
        check(!taps.flagsChanged(optionDown: true, otherModifiers: false, keyCode: 58, at: 1), "Option down does not start")
        check(!taps.flagsChanged(optionDown: false, otherModifiers: false, keyCode: 58, at: 1.1), "First tap does not start")
        check(!taps.flagsChanged(optionDown: true, otherModifiers: false, keyCode: 58, at: 1.2), "Second down does not start")
        check(taps.flagsChanged(optionDown: false, otherModifiers: false, keyCode: 58, at: 1.3), "Two complete clean taps start")
        check(!taps.flagsChanged(optionDown: false, otherModifiers: false, keyCode: 58, at: 1.31), "Duplicate release does not start")

        taps.invalidate()
        _ = taps.flagsChanged(optionDown: true, otherModifiers: false, keyCode: 58, at: 2)
        check(!taps.flagsChanged(optionDown: false, otherModifiers: false, keyCode: 58, at: 2.8), "Held Option does not arm")
        _ = taps.flagsChanged(optionDown: true, otherModifiers: false, keyCode: 58, at: 2.9)
        check(!taps.flagsChanged(optionDown: false, otherModifiers: false, keyCode: 58, at: 3), "Tap after hold is only first tap")
        taps.invalidate() // Production key-down and mouse-click handling calls this.
        _ = taps.flagsChanged(optionDown: true, otherModifiers: false, keyCode: 58, at: 3.1)
        check(!taps.flagsChanged(optionDown: false, otherModifiers: false, keyCode: 58, at: 3.2), "Typing clears pending pair")

        check(!taps.flagsChanged(optionDown: false, otherModifiers: true, keyCode: 56, at: 3.3), "Other modifier clears pair")
        _ = taps.flagsChanged(optionDown: true, otherModifiers: false, keyCode: 61, at: 3.4)
        check(!taps.flagsChanged(optionDown: false, otherModifiers: false, keyCode: 61, at: 3.5), "Tap after modifier is first tap")
        _ = taps.flagsChanged(optionDown: true, otherModifiers: false, keyCode: 58, at: 3.6)
        check(!taps.flagsChanged(optionDown: true, otherModifiers: false, keyCode: 61, at: 3.7), "Both Option keys invalidate")
        check(!taps.flagsChanged(optionDown: false, otherModifiers: false, keyCode: 61, at: 3.8), "Release of dirty press does not arm")

        taps.invalidate()
        _ = taps.flagsChanged(optionDown: true, otherModifiers: false, keyCode: 61, at: 4)
        _ = taps.flagsChanged(optionDown: false, otherModifiers: false, keyCode: 61, at: 4.1)
        _ = taps.flagsChanged(optionDown: true, otherModifiers: false, keyCode: 61, at: 5)
        check(!taps.flagsChanged(optionDown: false, otherModifiers: false, keyCode: 61, at: 5.1), "Separated taps do not start")
        _ = taps.flagsChanged(optionDown: true, otherModifiers: false, keyCode: 61, at: 6)
        check(!taps.flagsChanged(optionDown: false, otherModifiers: false, keyCode: 61, at: 5.9), "Reversed timestamps do not start")

        var keys = ShortcutKeyRecognizer()
        check(keys.keyDown(code: 53, flags: [], repeated: false, consumesEscape: false, pasteLastEnabled: true) == .passThrough,
              "Idle/meeting Escape passes through")
        check(keys.keyDown(code: 53, flags: [], repeated: false, consumesEscape: true, pasteLastEnabled: true) == .cancel,
              "Dictation Escape cancels once")
        check(keys.keyDown(code: 53, flags: [], repeated: true, consumesEscape: false, pasteLastEnabled: true) == .consume,
              "Escape repeats remain consumed after cancellation")
        check(keys.consumesKeyUp(code: 53), "Cancelled Escape release consumed")
        check(!keys.consumesKeyUp(code: 53), "Only one release consumed")
        check(keys.keyDown(code: 53, flags: [], repeated: false, consumesEscape: false, pasteLastEnabled: true) == .passThrough,
              "New idle Escape passes through")
        check(keys.keyDown(code: 9, flags: [.maskAlternate, .maskShift], repeated: false, consumesEscape: false, pasteLastEnabled: true) == .pasteLast,
              "Enabled exact paste-last binding triggers")
        check(keys.keyDown(code: 9, flags: [.maskAlternate, .maskShift], repeated: true, consumesEscape: false, pasteLastEnabled: true) == .consume,
              "Paste-last repeats cannot leak to other app")
        check(keys.keyDown(code: 9, flags: [.maskCommand, .maskShift, .maskAlternate], repeated: false, consumesEscape: false, pasteLastEnabled: true) == .passThrough,
              "Different paste binding passes through")
        check(keys.keyDown(code: 9, flags: [.maskAlternate, .maskShift], repeated: false, consumesEscape: false, pasteLastEnabled: false) == .passThrough,
              "Disabled paste-last binding preserves ordinary app shortcuts")
        print("Native shortcut selftest passed (24 checks)")
    }
}
