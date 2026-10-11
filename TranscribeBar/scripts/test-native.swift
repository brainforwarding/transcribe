import Foundation
import CoreGraphics
import Security
import AppKit

@main
struct NativeSelftest {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }

    @MainActor static func main() async {
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
        check(Keychain.account(for: .team) == "openai-api-key", "Legacy Team Keychain account remains unchanged")
        check(Keychain.account(for: .openAI) != Keychain.account(for: .team), "Direct key uses a distinct account")
        var providerReads: [ConnectionProvider: Int] = [:]
        var providerWrites: [ConnectionProvider] = []
        let vault = CredentialVault(read: { provider, _ in
            providerReads[provider, default: 0] += 1
            return provider == .team ? .value("local-test-team") : .missing
        }, write: { provider, _ in providerWrites.append(provider) })
        check(vault.fingerprint(.team) == nil && vault.fingerprint(.openAI) == nil && providerReads.isEmpty,
              "Rendering provider metadata never reads either credential")
        check(vault.get(.team) == "local-test-team" && vault.get(.team) == "local-test-team" && providerReads[.team] == 1,
              "Legacy Team cache loads once without touching direct account")
        check(vault.get(.openAI) == nil && vault.get(.openAI) == nil && providerReads[.openAI] == 1,
              "Direct missing result caches independently")
        do { try vault.set("local-test-direct", for: .openAI) } catch { check(false, "Synthetic direct save failed") }
        check(providerWrites == [.openAI] && vault.get(.team) == "local-test-team" && vault.get(.openAI) == "local-test-direct",
              "Direct save cannot alter or replace the legacy Team value")
        check(vault.status(.team) == errSecSuccess && vault.status(.openAI) == errSecSuccess,
              "Status belongs to each selected provider cache")
        let blockedVault = CredentialVault(read: { provider, _ in
            provider == .team ? .blocked(errSecInteractionNotAllowed) : .value("local-test-direct")
        }, write: { _, _ in })
        check(blockedVault.get(.team) == nil && blockedVault.get(.openAI) != nil,
              "A blocked Team account cannot block or populate direct account")
        check(blockedVault.status(.team) == errSecInteractionNotAllowed && blockedVault.status(.openAI) == errSecSuccess,
              "Blocked status does not leak between providers")
        await pasteChecks()
        print("Native shortcut/cache/paste selftest passed (\(checks) checks)")
    }

    @MainActor static func pasteChecks() async {
        func editable(_ role: String? = kAXTextAreaRole, _ subrole: String? = nil,
                      _ protected: Bool? = nil, _ enabled: Bool? = true,
                      _ explicit: Bool? = nil, _ writable: Bool = true) -> Bool {
            PasteTargetPolicy.isEditable(role: role, subrole: subrole, protected: protected, enabled: enabled,
                explicitEditable: explicit, selectedTextWritable: writable, valueWritable: false)
        }
        check(editable(), "Positive writable text area is eligible")
        check(!editable(kAXTextFieldRole, kAXSecureTextFieldSubrole), "Secure input is rejected")
        check(!editable(kAXTextAreaRole, nil, true), "Protected input is rejected")
        check(!editable(kAXTextAreaRole, nil, nil, false), "Disabled input is rejected")
        check(!editable(kAXTextAreaRole, nil, nil, true, false), "Explicit read-only input overrides writable metadata")
        check(!editable(kAXTextAreaRole, nil, nil, true, nil, false), "Selectable text alone is not editable")
        check(!editable("AXWebArea"), "Web container cannot receive a paste")
        check(editable(kAXTextFieldRole, nil, nil, true, true, false), "Explicit editability is accepted without AX setter")
        func terminal(_ role: String? = kAXTextAreaRole, _ subrole: String? = nil,
                      _ protected: Bool? = nil, _ enabled: Bool? = true, _ window: Bool = true) -> Bool {
            PasteTargetPolicy.isTerminalInput(role: role, subrole: subrole, protected: protected,
                enabled: enabled, hasFocusedWindow: window)
        }
        check(terminal(), "Known-terminal text area requires no writable scrollback attribute")
        check(!terminal(kAXGroupRole) && !terminal(kAXWindowRole) && !terminal(nil), "Terminal group/window/missing focus is rejected")
        check(!terminal(kAXTextAreaRole, kAXSecureTextFieldSubrole), "Secure terminal field is rejected")
        check(!terminal(kAXTextAreaRole, nil, true), "Protected terminal field is rejected")
        check(!terminal(kAXTextAreaRole, nil, nil, false), "Disabled terminal field is rejected")
        check(!terminal(kAXTextAreaRole, nil, nil, true, false), "Terminal without focused window is rejected")
        let controls = String(String.UnicodeScalarView((Array(0...0x1F) + Array(0x7F...0x9F) + [0x2028, 0x2029]).map { UnicodeScalar($0)! }))
        check(PasteTargetPolicy.terminalPayload(controls).unicodeScalars.allSatisfy { $0.value == 0x20 }, "Every C0/C1/DEL and Unicode line separator becomes space")
        let prose = "Hola Sebastián 👩🏽‍💻 café.\r\nSecond\tline\u{1B}[31m"
        let oneLine = PasteTargetPolicy.terminalPayload(prose)
        check(oneLine == "Hola Sebastián 👩🏽‍💻 café.  Second line [31m", "Accents/emoji/prose stay intact while delivery controls are removed")
        check(PasteTargetPolicy.terminalPayload(controls).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Control-only payload becomes empty delivery")

        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let binaryType = NSPasteboard.PasteboardType("com.transcribe.selftest.binary")
        let binary = Data([0, 255, 17, 128])
        func original() {
            board.clearContents()
            let first = NSPasteboardItem(); first.setString("original", forType: .string); first.setData(binary, forType: binaryType)
            let second = NSPasteboardItem(); second.setString("second", forType: .string)
            check(board.writeObjects([first, second]), "Named clipboard fixture can be written")
        }
        original()
        let transaction = PasteboardTransaction(board: board)!
        check(transaction.write("synthetic transcript"), "Temporary transcript writes to named clipboard")
        check(transaction.restoreIfOwned(), "Owned clipboard restores")
        check(board.pasteboardItems?.count == 2 && board.pasteboardItems?.first?.data(forType: binaryType) == binary
              && board.pasteboardItems?.last?.string(forType: .string) == "second", "All formats and multiple clipboard items survive")
        let lost = PasteboardTransaction(board: board)!
        check(lost.write("temporary"), "Ownership test writes temporary text")
        board.clearContents(); board.setString("new user copy", forType: .string)
        check(!lost.restoreIfOwned() && board.string(forType: .string) == "new user copy", "A newer user clipboard owner is never overwritten")

        var posts = 0
        let engine = CurrentCaretPasteTransaction(board: board, wait: {})
        let denied = await engine.run("synthetic", canDeliver: { false }, targetStillValid: { true }, postPaste: { posts += 1 }, verify: { false })
        if case .ready = denied { check(posts == 0 && board.string(forType: .string) == "new user copy", "Revoked delivery emits zero keys and leaves clipboard alone") }
        else { check(false, "Revoked delivery must be ready") }

        var targetChecks = 0
        let changed = await engine.run("synthetic", canDeliver: { true }, targetStillValid: {
            targetChecks += 1; return targetChecks < 3
        }, postPaste: { posts += 1 }, verify: { false })
        if case .ready = changed { check(posts == 0 && board.string(forType: .string) == "new user copy", "Focus invalidation after clipboard write restores without key posts") }
        else { check(false, "Invalidated predispatch target must be ready") }

        let confirmed = await engine.run("synthetic", canDeliver: { true }, targetStillValid: { true }, postPaste: { posts += 1 }, verify: { true })
        check(confirmed == .inserted && posts == 1 && board.string(forType: .string) == "new user copy", "Confirmed consumption restores original clipboard")

        let cancelledTask = Task { @MainActor in
            await engine.run("synthetic", canDeliver: { true }, targetStillValid: { true }, postPaste: {
                posts += 1; withUnsafeCurrentTask { $0?.cancel() }
            }, verify: { false })
        }
        let cancelledOutcome = await cancelledTask.value
        if case .unconfirmed = cancelledOutcome { check(posts == 2 && board.string(forType: .string) == "synthetic", "Cancellation after dispatch retains transcript for a delayed receiver") }
        else { check(false, "Dispatched cancelled paste remains unconfirmed") }

        var polls = 0
        let newOwnerEngine = CurrentCaretPasteTransaction(board: board, wait: {
            board.clearContents(); board.setString("newer clipboard", forType: .string)
        })
        let newer = await newOwnerEngine.run("synthetic", canDeliver: { true }, targetStillValid: { true }, postPaste: { posts += 1 }, verify: { polls += 1; return polls > 1 })
        check(newer == .inserted && board.string(forType: .string) == "newer clipboard", "Ownership change during confirmation wait prevents restoration")
        let unconfirmedNewOwner = await newOwnerEngine.run("synthetic", canDeliver: { true }, targetStillValid: { true }, postPaste: { posts += 1 }, verify: { false })
        if case .unconfirmed(let reason) = unconfirmedNewOwner {
            check(!reason.contains("remains on the clipboard") && board.string(forType: .string) == "newer clipboard",
                  "Unconfirmed delivery never falsely claims clipboard ownership after user copy")
        } else { check(false, "Unverified delivery must remain unconfirmed") }

        var blocked: CheckedContinuation<Void, Never>?
        let overlapEngine = CurrentCaretPasteTransaction(board: board, wait: {
            if blocked == nil { await withCheckedContinuation { blocked = $0 } }
        })
        let first = Task { @MainActor in
            await overlapEngine.run("first synthetic", canDeliver: { true }, targetStillValid: { true }, postPaste: { posts += 1 }, verify: { false })
        }
        while blocked == nil { await Task.yield() }
        let beforeOverlap = posts
        let second = await overlapEngine.run("second synthetic", canDeliver: { true }, targetStillValid: { true }, postPaste: { posts += 1 }, verify: { true })
        if case .unconfirmed = second { check(posts == beforeOverlap && board.string(forType: .string) == "first synthetic", "Overlapping paste cannot replace in-flight clipboard or send extra keys") }
        else { check(false, "Overlapping delivery must be blocked") }
        blocked?.resume()
        _ = await first.value

        let beforeTerminal = posts
        let terminalSent = await engine.run(oneLine, canDeliver: { true }, targetStillValid: { true },
            postPaste: { posts += 1 }, verify: { true }, terminal: true)
        if case .unconfirmed(let reason) = terminalSent {
            check(posts == beforeTerminal + 1 && board.string(forType: .string) == oneLine && reason.contains("sent as one line"),
                  "Terminal dispatch never claims verification or restores unrelated old clipboard")
        } else { check(false, "Terminal dispatch must remain unconfirmed") }
        let beforeTerminalCancel = posts
        let terminalCancelled = await engine.run(oneLine, canDeliver: { false }, targetStillValid: { true },
            postPaste: { posts += 1 }, verify: { false }, terminal: true)
        if case .ready = terminalCancelled { check(posts == beforeTerminalCancel && board.string(forType: .string) == oneLine, "Cancelled terminal delivery sends no keys") }
        else { check(false, "Cancelled terminal delivery must be ready") }
        var terminalIdentityChecks = 0
        let terminalChanged = await engine.run(oneLine, canDeliver: { true }, targetStillValid: {
            terminalIdentityChecks += 1; return terminalIdentityChecks < 3
        }, postPaste: { posts += 1 }, verify: { false }, terminal: true)
        if case .ready = terminalChanged { check(posts == beforeTerminalCancel && board.string(forType: .string) == oneLine, "Terminal focus/window invalidation before post sends no keys and restores clipboard") }
        else { check(false, "Changed terminal destination must be ready") }
        let terminalNewCopy = await newOwnerEngine.run(oneLine, canDeliver: { true }, targetStillValid: { true },
            postPaste: { posts += 1 }, verify: { false }, terminal: true)
        if case .unconfirmed(let reason) = terminalNewCopy { check(!reason.contains("remains on the clipboard") && board.string(forType: .string) == "newer clipboard", "Terminal wait preserves external clipboard owner") }
        else { check(false, "Unverifiable terminal paste remains unconfirmed") }
        let ordinaryText = "First paragraph\n\nSecond\tparagraph 👩🏽‍💻"
        let ordinarySent = await engine.run(ordinaryText, canDeliver: { true }, targetStillValid: { true }, postPaste: {
            check(board.string(forType: .string) == ordinaryText, "Ordinary editors retain exact multiline formatting")
        }, verify: { true })
        check(ordinarySent == .inserted, "Ordinary editor confirmation behavior is unchanged")
    }
}
