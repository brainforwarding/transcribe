import Foundation
import AVFoundation
import CoreGraphics
import ScreenCaptureKit
import AppKit

/// TCC permission probes + triggers. Screen Recording status is probed via SCShareableContent
/// (the same call capture uses) rather than CGPreflightScreenCaptureAccess (which warns on
/// 15.1+). Granting Screen Recording requires an app relaunch to take effect.
enum Permissions {

    static func micAuthorized() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestMic() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// True if Screen Recording is granted (we can enumerate shareable displays).
    static func screenAuthorized() async -> Bool {
        if #available(macOS 13.0, *) {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                return !content.displays.isEmpty
            } catch {
                return false
            }
        }
        return false
    }

    /// Triggers the Screen Recording prompt (no-op if already granted). Effect needs a relaunch.
    static func requestScreen() {
        CGRequestScreenCaptureAccess()
    }

    static func openScreenSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }
    static func openMicSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }
    private static func open(_ s: String) {
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
        else { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security")!) }
    }

    /// Relaunch the app so a freshly-granted Screen Recording permission takes effect.
    static func relaunch() {
        let url = Bundle.main.bundleURL
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", url.path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
