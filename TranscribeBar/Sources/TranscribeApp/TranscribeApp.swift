import SwiftUI

#if TRANSCRIBE_INSERTION_DIAGNOSTICS
import ApplicationServices

/// Compile-only validation entry point. Normal releases do not contain this action.
@main
struct TranscribeInsertionDiagnostics {
    @MainActor
    static func main() async {
        _ = NSApplication.shared
        let fixtures = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == "com.sebastianmarambio.transcribe.paste-fixture"
        }
        guard fixtures.count == 1, let app = fixtures.first else {
            print("{\"fixtureGuardPassed\":false}")
            return
        }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        var focused: CFTypeRef?
        let focusStatus = AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focused)
        var diagnostics: [String: Any] = ["fixtureGuardPassed": true,
                                          "accessibilityTrusted": AXIsProcessTrusted(),
                                          "focusStatus": focusStatus.rawValue]
        guard focusStatus == .success, let focused,
              CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            emit(diagnostics)
            return
        }
        let element = focused as! AXUIElement
        for name in [kAXRoleAttribute, kAXSubroleAttribute, kAXValueAttribute, kAXSelectedTextRangeAttribute] {
            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
            diagnostics[name + "Status"] = status.rawValue
            if name == kAXRoleAttribute || name == kAXSubroleAttribute {
                diagnostics[name] = value as? String ?? "unavailable"
            }
            if name == kAXValueAttribute { diagnostics["initialCharacterCount"] = (value as? String).map { ($0 as NSString).length } ?? -1 }
        }
        var settable: DarwinBoolean = false
        let settableStatus = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
        diagnostics["selectedTextSettableStatus"] = settableStatus.rawValue
        diagnostics["selectedTextSettable"] = settable.boolValue
        diagnostics["fixtureFrontmost"] = NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
        guard diagnostics["fixtureFrontmost"] as? Bool == true else {
            diagnostics["writeSkipped"] = true
            emit(diagnostics)
            return
        }
        var fixtureValue: CFTypeRef?
        var fixtureSelection: CFTypeRef?
        var fixtureRange = CFRange()
        let hasEmptyValue = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &fixtureValue) == .success
            && fixtureValue as? String == ""
        let hasRange = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &fixtureSelection) == .success
        let rangeValue = fixtureSelection.flatMap { CFGetTypeID($0) == AXValueGetTypeID() ? ($0 as! AXValue) : nil }
        let hasEmptyCaret = hasRange && rangeValue.map {
            AXValueGetType($0) == .cfRange && AXValueGetValue($0, .cfRange, &fixtureRange)
                && fixtureRange.location == 0 && fixtureRange.length == 0
        } == true
        diagnostics["fixtureContentGuardPassed"] = hasEmptyValue && hasEmptyCaret
        guard hasEmptyValue && hasEmptyCaret else { emit(diagnostics); return }
        let service = PasteService()
        let sentinel = "Transcribe controlled insertion fixture."
        switch service.captureDestinationResult() {
        case .unavailable(let reason):
            diagnostics["captureOutcome"] = "unavailable"
            diagnostics["captureReason"] = reason
        case .captured(let destination):
            diagnostics["captureOutcome"] = "captured"
            guard service.diagnosticMatches(destination, processID: app.processIdentifier, element: element) else {
                diagnostics["destinationGuardPassed"] = false
                emit(diagnostics)
                return
            }
            diagnostics["destinationGuardPassed"] = true
            switch service.insert(sentinel, at: destination) {
            case .inserted: diagnostics["insertOutcome"] = "inserted"
            case .ready(let reason): diagnostics["insertOutcome"] = "ready"; diagnostics["insertReason"] = reason
            case .unconfirmed(let reason): diagnostics["insertOutcome"] = "unconfirmed"; diagnostics["insertReason"] = reason
            }
            diagnostics["writeStatus"] = service.diagnosticWriteStatus?.rawValue
            try? await Task.sleep(nanoseconds: 500_000_000)
            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
            diagnostics["delayedValueStatus"] = status.rawValue
            diagnostics["delayedExactSentinel"] = value as? String == sentinel
            diagnostics["delayedCharacterCount"] = (value as? String).map { ($0 as NSString).length } ?? -1
        }
        emit(diagnostics)
    }

    static func emit(_ diagnostics: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: diagnostics, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) { print(text) }
    }
}
#else
@main
struct TranscribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // No window scene — the AppDelegate owns the menu-bar status item + popover.
        Settings { EmptyView() }
    }
}
#endif
