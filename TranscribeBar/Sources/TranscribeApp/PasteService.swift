import AppKit
import ApplicationServices
import CryptoKit

/// Inserts only into a still-valid accessible field. Recording never uses the clipboard.
@MainActor
final class PasteService {
#if TRANSCRIBE_INSERTION_DIAGNOSTICS
    private(set) var diagnosticWriteStatus: AXError?
    func diagnosticMatches(_ destination: Destination, processID: pid_t, element: AXUIElement) -> Bool {
        destination.processID == processID && CFEqual(destination.element, element)
    }
#endif
    struct Destination {
        fileprivate let processID: pid_t
        fileprivate let element: AXUIElement
        fileprivate let range: CFRange
        fileprivate let fingerprint: String
    }

    enum Outcome: Equatable {
        case inserted
        case ready(reason: String)
        /// A write was attempted, but its result is unknown. Do not paste or copy again automatically.
        case unconfirmed(reason: String)
    }

    enum CaptureOutcome {
        case captured(Destination)
        case unavailable(reason: String)
    }

    func captureDestination() -> Destination? {
        if case .captured(let destination) = captureDestinationResult() { return destination }
        return nil
    }

    func captureDestinationResult() -> CaptureOutcome {
        guard AXIsProcessTrusted() else {
            return .unavailable(reason: "Enable Accessibility to insert text.")
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return .unavailable(reason: "Select a text field in another app before recording.")
        }
        guard let element = focusedElement(in: app.processIdentifier) else {
            return .unavailable(reason: "The selected app did not expose a focused text field.")
        }
        guard isEditable(element) else {
            return .unavailable(reason: "The selected field does not allow accessible text insertion.")
        }
        guard let value = stringAttribute(element, kAXValueAttribute) else {
            return .unavailable(reason: "The selected field did not expose its text for safe insertion.")
        }
        guard let range = selectedRange(element), valid(range, in: value) else {
            return .unavailable(reason: "The selected field did not expose a valid cursor position.")
        }
        return .captured(Destination(processID: app.processIdentifier, element: element,
                                     range: range, fingerprint: fingerprint(value)))
    }

    func insert(_ text: String, at destination: Destination) -> Outcome {
        guard !text.isEmpty else { return .ready(reason: "No text to insert.") }
        guard AXIsProcessTrusted() else { return .ready(reason: "Enable Accessibility to insert text.") }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == destination.processID,
              let focused = focusedElement(in: destination.processID),
              CFEqual(focused, destination.element), isEditable(focused),
              let value = stringAttribute(focused, kAXValueAttribute),
              fingerprint(value) == destination.fingerprint,
              let range = selectedRange(focused), same(range, destination.range),
              valid(range, in: value)
        else { return .ready(reason: "Your cursor moved. The transcript is ready to copy.") }

        let expected = (value as NSString).replacingCharacters(
            in: NSRange(location: range.location, length: range.length), with: text)
        let expectedCaret = CFRange(location: range.location + (text as NSString).length, length: 0)
        let status = AXUIElementSetAttributeValue(focused, kAXSelectedTextAttribute as CFString, text as CFString)
#if TRANSCRIBE_INSERTION_DIAGNOSTICS
        diagnosticWriteStatus = status
#endif
        guard status == .success else {
            return .unconfirmed(reason: "Insertion could not be confirmed. Check the original field before pasting again.")
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == destination.processID,
              let currentFocus = focusedElement(in: destination.processID), CFEqual(currentFocus, focused),
              stringAttribute(focused, kAXValueAttribute) == expected,
              let verifiedRange = selectedRange(focused), same(verifiedRange, expectedCaret)
        else { return .unconfirmed(reason: "Insertion could not be confirmed. Check the original field before pasting again.") }
        return .inserted
    }

    /// An explicit paste-last command intentionally captures the current, rather than old, caret.
    func pasteAtCurrentCaret(_ text: String) -> Outcome {
        switch captureDestinationResult() {
        case .captured(let destination): return insert(text, at: destination)
        case .unavailable(let reason): return .ready(reason: reason)
        }
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

    private func isEditable(_ element: AXUIElement) -> Bool {
        guard stringAttribute(element, kAXSubroleAttribute) != kAXSecureTextFieldSubrole else { return false }
        var protected: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXProtectedContent" as CFString, &protected) == .success,
           (protected as? Bool) == true { return false }
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success
            && settable.boolValue
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

    private func fingerprint(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func valid(_ range: CFRange, in value: String) -> Bool {
        let count = (value as NSString).length
        return range.location >= 0 && range.length >= 0 && range.location <= count && range.length <= count - range.location
    }

    private func same(_ lhs: CFRange, _ rhs: CFRange) -> Bool {
        lhs.location == rhs.location && lhs.length == rhs.length
    }
}
