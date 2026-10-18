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
        service.diagnosticTarget = (app.processIdentifier, element)
        let sentinel = "Transcribe controlled insertion fixture."
        let result = await service.deliverAtCurrentCaret(sentinel, canDeliver: {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return false }
            var value: CFTypeRef?
            var selected: CFTypeRef?
            var range = CFRange()
            guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
                  value as? String == "",
                  AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selected) == .success,
                  let selected, CFGetTypeID(selected) == AXValueGetTypeID() else { return false }
            let selection = selected as! AXValue
            return AXValueGetType(selection) == .cfRange && AXValueGetValue(selection, .cfRange, &range)
                && range.location == 0 && range.length == 0
        })
        switch result {
            case .inserted: diagnostics["insertOutcome"] = "inserted"
            case .ready(let reason): diagnostics["insertOutcome"] = "ready"; diagnostics["insertReason"] = reason
            case .unconfirmed(let reason): diagnostics["insertOutcome"] = "unconfirmed"; diagnostics["insertReason"] = reason
        }
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        diagnostics["delayedValueStatus"] = status.rawValue
        diagnostics["delayedExactSentinel"] = value as? String == sentinel
        diagnostics["delayedCharacterCount"] = (value as? String).map { ($0 as NSString).length } ?? -1
        emit(diagnostics)
    }

    static func emit(_ diagnostics: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: diagnostics, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) { print(text) }
    }
}
#elseif TRANSCRIBE_DICTATION_BENCHMARK
// The isolated, compile-only entry point is in DictationBenchmark.swift.
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
