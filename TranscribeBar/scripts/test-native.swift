import Foundation
import CoreGraphics
import Security

@main
struct NativeSelftest {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
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
        let sessionID = UUID(), nextSessionID = UUID()
        var modeTaps = OptionTapRecognizer()
        check(modeTaps.flagsChanged(optionDown: true, otherModifiers: false, keyCode: 58, at: 10, context: .capturing(sessionID)) == nil,
              "Recording Option press alone does not stop")
        check(modeTaps.flagsChanged(optionDown: false, otherModifiers: false, keyCode: 58, at: 10.1, context: .capturing(sessionID)) == .stop(sessionID),
              "One clean recording Option tap stops exact session")
        check(modeTaps.flagsChanged(optionDown: false, otherModifiers: false, keyCode: 58, at: 10.2, context: .capturing(sessionID)) == nil,
              "Duplicate recording release does not stop again")
        _ = modeTaps.flagsChanged(optionDown: true, otherModifiers: false, keyCode: 61, at: 11, context: .capturing(sessionID))
        check(modeTaps.flagsChanged(optionDown: false, otherModifiers: false, keyCode: 61, at: 11.8, context: .capturing(sessionID)) == nil,
              "Holding recording Option does not stop")
        _ = modeTaps.flagsChanged(optionDown: true, otherModifiers: false, keyCode: 58, at: 12, context: .capturing(sessionID))
        modeTaps.invalidate()
        check(modeTaps.flagsChanged(optionDown: false, otherModifiers: false, keyCode: 58, at: 12.1, context: .capturing(sessionID)) == nil,
              "Typing or mouse click prevents recording stop")
        _ = modeTaps.flagsChanged(optionDown: true, otherModifiers: false, keyCode: 58, at: 13, context: .capturing(sessionID))
        _ = modeTaps.flagsChanged(optionDown: true, otherModifiers: true, keyCode: 56, at: 13.05, context: .capturing(sessionID))
        check(modeTaps.flagsChanged(optionDown: false, otherModifiers: false, keyCode: 58, at: 13.1, context: .capturing(sessionID)) == nil,
              "Modified recording Option does not stop")
        _ = modeTaps.flagsChanged(optionDown: true, otherModifiers: false, keyCode: 58, at: 14, context: .capturing(sessionID))
        check(modeTaps.flagsChanged(optionDown: false, otherModifiers: false, keyCode: 58, at: 14.1, context: .capturing(nextSessionID)) == nil,
              "Session transition invalidates held Option")
        _ = modeTaps.flagsChanged(optionDown: true, otherModifiers: false, keyCode: 58, at: 15, context: .disabled)
        check(modeTaps.flagsChanged(optionDown: false, otherModifiers: false, keyCode: 58, at: 15.1, context: .disabled) == nil,
              "Meetings and processing never use single Option stop")
        _ = modeTaps.flagsChanged(optionDown: true, otherModifiers: false, keyCode: 58, at: 16, context: .idle)
        check(modeTaps.flagsChanged(optionDown: false, otherModifiers: false, keyCode: 58, at: 16.1, context: .idle) == nil,
              "Idle remains double-tap start after mode transitions")
        _ = modeTaps.flagsChanged(optionDown: true, otherModifiers: false, keyCode: 61, at: 16.2, context: .idle)
        check(modeTaps.flagsChanged(optionDown: false, otherModifiers: false, keyCode: 61, at: 16.3, context: .idle) == .start,
              "Both left and right Option work for double-tap start")
        check(!OptionShortcutAction.stop(sessionID).isApplicable(to: .idle), "Queued stop cannot restart idle app")
        check(!OptionShortcutAction.stop(sessionID).isApplicable(to: .capturing(nextSessionID)), "Queued stop cannot stop new session")
        check(!OptionShortcutAction.start.isApplicable(to: .capturing(sessionID)), "Queued start cannot toggle active recording")
        check(OptionShortcutAction.stop(sessionID).isApplicable(to: .capturing(sessionID)), "Queued stop requires same active session")

        var reads = [Bool]()
        var failWrite = false
        let cache = CredentialSession(read: { interactive in reads.append(interactive); return .value("local-test-original") },
                                      write: { _ in if failWrite { throw Keychain.StorageError(status: errSecAuthFailed) } })
        check(cache.cachedFingerprint == nil && reads.isEmpty, "Rendering fingerprint does not load Keychain")
        check(cache.get() != nil && cache.get() != nil && reads == [false], "Repeated normal reads use one noninteractive load")
        check(cache.cachedReadStatus == errSecSuccess && cache.cachedFingerprint != nil && reads == [false], "Cached display metadata never starts another read")
        failWrite = true
        do { try cache.set("local-test-updated"); check(false, "Write failure must propagate") }
        catch { check(cache.get() == "local-test-original" && reads == [false], "Failed save preserves old session credential") }
        failWrite = false
        do { try cache.set("local-test-updated") } catch { check(false, "Successful fake save unexpectedly failed") }
        check(cache.get() == "local-test-updated" && reads == [false], "Successful save refreshes cache without reread")

        var missingReads = 0
        let missing = CredentialSession(read: { _ in missingReads += 1; return .missing }, write: { _ in })
        check(missing.get() == nil && missing.get() == nil && missingReads == 1, "Missing credential results are cached")
        check(missing.cachedReadStatus == errSecItemNotFound, "Missing cache keeps exact safe status")
        var deniedModes = [Bool]()
        let denied = CredentialSession(read: { interactive in
            deniedModes.append(interactive); return interactive ? .value("local-test-unlocked") : .blocked(errSecInteractionNotAllowed)
        }, write: { _ in })
        check(denied.get() == nil && denied.get() == nil && deniedModes == [false], "Denied normal reads are cached without repeated prompts")
        check(denied.cachedReadStatus == errSecInteractionNotAllowed, "Denied cache exposes safe access-required status")
        check(denied.unlock() != nil && denied.get() != nil && deniedModes == [false, true], "Only deliberate unlock retries interactively and then caches")
        check(denied.cachedReadStatus == errSecSuccess, "Successful deliberate unlock clears denied status")
        print("Native shortcut/cache selftest passed (\(checks) checks)")
    }
}
