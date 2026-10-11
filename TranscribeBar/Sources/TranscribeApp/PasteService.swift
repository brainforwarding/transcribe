import AppKit
import ApplicationServices

struct PasteTargetPolicy {
    static func isEditable(role: String?, subrole: String?, protected: Bool?, enabled: Bool?,
                           explicitEditable: Bool?, selectedTextWritable: Bool, valueWritable: Bool) -> Bool {
        guard role == kAXTextFieldRole || role == kAXTextAreaRole,
              subrole != kAXSecureTextFieldSubrole, protected != true, enabled != false else { return false }
        return explicitEditable ?? (selectedTextWritable || valueWritable)
    }

    static func isTerminalInput(role: String?, subrole: String?, protected: Bool?, enabled: Bool?, hasFocusedWindow: Bool) -> Bool {
        hasFocusedWindow && role == kAXTextAreaRole && subrole != kAXSecureTextFieldSubrole && protected != true && enabled != false
    }

    /// Only the terminal delivery payload changes; saved transcripts and explicit Copy stay intact.
    static func terminalPayload(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            let value = scalar.value
            return value <= 0x1F || (0x7F...0x9F).contains(value) || value == 0x2028 || value == 0x2029
                ? UnicodeScalar(0x20)! : scalar
        }))
    }
}

/// A temporary clipboard replacement. Data stays in memory and is never logged.
@MainActor
final class PasteboardTransaction {
    private let board: NSPasteboard
    private let initialChangeCount: Int
    private let items: [[(NSPasteboard.PasteboardType, Data)]]
    private var writtenChangeCount: Int?

    init?(board: NSPasteboard) {
        let initial = board.changeCount
        var snapshot: [[(NSPasteboard.PasteboardType, Data)]] = []
        let existingItems = board.pasteboardItems ?? []
        guard !existingItems.isEmpty || (board.types?.isEmpty ?? true) else { return nil }
        for item in existingItems {
            guard !item.types.isEmpty else { return nil }
            var values: [(NSPasteboard.PasteboardType, Data)] = []
            for type in item.types {
                guard let data = item.data(forType: type) else { return nil }
                values.append((type, data))
            }
            snapshot.append(values)
        }
        guard board.changeCount == initial else { return nil }
        self.board = board
        initialChangeCount = initial
        items = snapshot
    }

    var isOwned: Bool { writtenChangeCount.map { board.changeCount == $0 } ?? false }

    func write(_ text: String) -> Bool {
        guard board.changeCount == initialChangeCount else { return false }
        let ownedCount = board.clearContents()
        writtenChangeCount = ownedCount
        guard board.changeCount == ownedCount else { return false }
        guard board.setString(text, forType: .string) else { return false }
        // Never adopt a new owner's count after writing.
        return board.changeCount == ownedCount
    }

    @discardableResult
    func restoreIfOwned() -> Bool {
        guard let writtenChangeCount, board.changeCount == writtenChangeCount else { return false }
        var restored: [NSPasteboardItem] = []
        for values in items {
            let item = NSPasteboardItem()
            for (type, data) in values {
                guard item.setData(data, forType: type) else { return false }
            }
            restored.append(item)
        }
        // Rebuilding large items may take time while another process copies something new.
        guard board.changeCount == writtenChangeCount else { return false }
        let restoreCount = board.clearContents()
        guard board.changeCount == restoreCount else { return false }
        return restored.isEmpty || board.writeObjects(restored)
    }
}

/// Tests exercise this same transaction with an isolated named pasteboard and fake event post.
@MainActor
final class CurrentCaretPasteTransaction {
    private let board: NSPasteboard
    private let wait: () async -> Void
    private var delivering = false

    init(board: NSPasteboard = .general, wait: @escaping () async -> Void = {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { continuation.resume() }
        }
    }) { self.board = board; self.wait = wait }

    func run(_ text: String, canDeliver: () -> Bool, targetStillValid: () -> Bool,
             postPaste: () -> Void, verify: () -> Bool, terminal: Bool = false) async -> PasteService.Outcome {
        guard !delivering else { return .unconfirmed(reason: "A paste is already in progress. Check the field before pasting again.") }
        delivering = true
        defer { delivering = false }
        guard canDeliver(), !Task.isCancelled, targetStillValid() else {
            return .ready(reason: "Paste was cancelled or the selected field changed. Your transcript is saved.")
        }
        guard let clipboard = PasteboardTransaction(board: board) else {
            return .ready(reason: "The clipboard could not be preserved. Your transcript is saved.")
        }
        guard canDeliver(), !Task.isCancelled, targetStillValid() else {
            return .ready(reason: "Paste was cancelled or the selected field changed. Your transcript is saved.")
        }
        guard clipboard.write(text) else {
            clipboard.restoreIfOwned()
            return .ready(reason: "The clipboard changed before paste. Your transcript is saved.")
        }
        // No suspension between this final authorization/focus check and both key events.
        guard canDeliver(), !Task.isCancelled, targetStillValid() else {
            clipboard.restoreIfOwned()
            return .ready(reason: "Paste was cancelled or the selected field changed. Your transcript is saved.")
        }
        postPaste()
        for _ in 0..<20 {
            if !terminal && verify() { clipboard.restoreIfOwned(); return .inserted }
            // Cancellation must not restore old contents before a delayed receiver consumes Cmd-V.
            await wait()
        }
        // Without confirmation, retaining the transcript avoids a late paste of unrelated old data.
        if terminal {
            return .unconfirmed(reason: clipboard.isOwned
                ? "The paste shortcut was sent as one line. Check the terminal. That line remains on the clipboard."
                : "The paste shortcut was sent as one line. Check the terminal before pasting again. Your transcript is saved.")
        }
        return .unconfirmed(reason: clipboard.isOwned
            ? "Paste could not be confirmed. Check the field. The transcript remains on the clipboard."
            : "Paste could not be confirmed. Check the field before pasting again. Your transcript is saved.")
    }
}

/// Pastes into the current editable field only after transcription is durably saved.
@MainActor
final class PasteService {
    private let currentCaretTransaction = CurrentCaretPasteTransaction()
#if TRANSCRIBE_INSERTION_DIAGNOSTICS
    var diagnosticTarget: (processID: pid_t, element: AXUIElement)?
#endif

    enum Outcome: Equatable {
        case inserted
        case ready(reason: String)
        /// A write was attempted, but its result is unknown. Do not paste or copy again automatically.
        case unconfirmed(reason: String)
    }

    private struct CurrentTarget {
        let processID: pid_t
        let element: AXUIElement
        let terminalWindow: AXUIElement?
        let initialValue: String?
        let initialRange: CFRange?
    }

    func deliverAtCurrentCaret(_ text: String, canDeliver: @escaping @MainActor () -> Bool) async -> Outcome {
        guard !text.isEmpty else { return .ready(reason: "No text to paste.") }
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
            return .ready(reason: "Enable Accessibility to paste into the selected field.")
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return .ready(reason: "Select an editable text field in another app.")
        }
        let terminal = Self.terminalBundleIDs.contains(app.bundleIdentifier ?? "")
        let terminalWindow = terminal ? focusedWindow(in: app.processIdentifier) : nil
        guard let element = focusedElement(in: app.processIdentifier),
              terminal ? isTerminalInput(element, hasFocusedWindow: terminalWindow != nil) : isPasteEditable(element) else {
            return .ready(reason: "The current field does not expose safe text editing. Select an editable text field.")
        }
        let payload = terminal ? PasteTargetPolicy.terminalPayload(text) : text
        guard !terminal || !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .ready(reason: "No text to paste.")
        }
#if TRANSCRIBE_INSERTION_DIAGNOSTICS
        if let required = diagnosticTarget,
           required.processID != app.processIdentifier || !CFEqual(required.element, element) {
            return .ready(reason: "The controlled fixture target changed.")
        }
#endif
        let value = terminal ? nil : stringAttribute(element, kAXValueAttribute)
        let range = terminal ? nil : selectedRange(element).flatMap { range in value.map { valid(range, in: $0) ? range : nil } ?? nil }
        let target = CurrentTarget(processID: app.processIdentifier, element: element, terminalWindow: terminalWindow, initialValue: value, initialRange: range)
        let expected = value.flatMap { value in range.map { (value as NSString).replacingCharacters(in: NSRange(location: $0.location, length: $0.length), with: payload) } }
        let expectedCaret = range.map { CFRange(location: $0.location + (payload as NSString).length, length: 0) }
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            return .ready(reason: "The paste shortcut could not be prepared. Your transcript is saved.")
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        return await currentCaretTransaction.run(payload, canDeliver: canDeliver, targetStillValid: {
            guard AXIsProcessTrusted(), CGPreflightPostEventAccess(),
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processID,
                  let focused = self.focusedElement(in: target.processID), CFEqual(focused, target.element),
                  terminal ? self.isTerminalInput(focused, hasFocusedWindow: target.terminalWindow != nil) : self.isPasteEditable(focused) else { return false }
            if let window = target.terminalWindow {
                guard let current = self.focusedWindow(in: target.processID), CFEqual(window, current) else { return false }
            }
            if let value = target.initialValue, self.stringAttribute(focused, kAXValueAttribute) != value { return false }
            if let range = target.initialRange {
                guard let current = self.selectedRange(focused), self.same(current, range) else { return false }
            }
            return true
        }, postPaste: {
            down.postToPid(target.processID)
            up.postToPid(target.processID)
        }, verify: {
            guard let expected, let expectedCaret,
                  self.stringAttribute(target.element, kAXValueAttribute) == expected,
                  let range = self.selectedRange(target.element), self.same(range, expectedCaret) else { return false }
            return true
        }, terminal: terminal)
    }

    private static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "net.kovidgoyal.kitty", "org.alacritty",
        "com.mitchellh.ghostty", "dev.warp.Warp-Stable", "dev.warp.Warp"
    ]

    private func isPasteEditable(_ element: AXUIElement) -> Bool {
        let role = stringAttribute(element, kAXRoleAttribute)
        let subrole = stringAttribute(element, kAXSubroleAttribute)
        func boolAttribute(_ name: String) -> Bool? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
            return value as? Bool
        }
        func writable(_ name: String) -> Bool {
            var settable: DarwinBoolean = false
            return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success && settable.boolValue
        }
        return PasteTargetPolicy.isEditable(role: role, subrole: subrole,
            protected: boolAttribute("AXProtectedContent"), enabled: boolAttribute(kAXEnabledAttribute),
            explicitEditable: boolAttribute("AXEditable"), selectedTextWritable: writable(kAXSelectedTextAttribute),
            valueWritable: writable(kAXValueAttribute))
    }

    private func isTerminalInput(_ element: AXUIElement, hasFocusedWindow: Bool) -> Bool {
        PasteTargetPolicy.isTerminalInput(role: stringAttribute(element, kAXRoleAttribute),
            subrole: stringAttribute(element, kAXSubroleAttribute),
            protected: boolAttribute(element, "AXProtectedContent"), enabled: boolAttribute(element, kAXEnabledAttribute), hasFocusedWindow: hasFocusedWindow)
    }

    private func boolAttribute(_ element: AXUIElement, _ name: String) -> Bool? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result as? Bool
    }

    private func focusedWindow(in processID: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(processID)
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &result) == .success,
              let result, CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return (result as! AXUIElement)
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func focusedElement(in processID: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(processID)
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &result) == .success,
              let result, CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return (result as! AXUIElement)
    }

    private func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func selectedRange(_ element: AXUIElement) -> CFRange? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &result) == .success,
              let result, CFGetTypeID(result) == AXValueGetTypeID() else { return nil }
        let value = result as! AXValue
        guard AXValueGetType(value) == .cfRange else { return nil }
        var range = CFRange()
        return AXValueGetValue(value, .cfRange, &range) ? range : nil
    }

    private func valid(_ range: CFRange, in value: String) -> Bool {
        let count = (value as NSString).length
        return range.location >= 0 && range.length >= 0 && range.location <= count && range.length <= count - range.location
    }

    private func same(_ lhs: CFRange, _ rhs: CFRange) -> Bool {
        lhs.location == rhs.location && lhs.length == rhs.length
    }
}
