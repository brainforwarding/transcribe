import AppKit
import SwiftUI
import Combine

/// Manages the menu-bar status item + popover via AppKit (more reliable than SwiftUI's
/// MenuBarExtra in a SwiftPM-built bundle, which can fail to show its icon).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            setIcon(recording: false)
            button.imagePosition = .imageLeading
            button.action = #selector(togglePopover)
            button.target = self
        }

        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: ContentView().environmentObject(model))

        model.showSettings = { [weak self] in self?.openSettings() }

        // Reflect recording state in the menu-bar icon.
        model.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in self?.setIcon(recording: phase == .recording) }
            .store(in: &cancellables)
    }

    private func setIcon(recording: Bool) {
        guard let button = statusItem?.button else { return }
        let name = recording ? "record.circle.fill" : "waveform"
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Transcribe")
        img?.isTemplate = true
        button.image = img
        // If the SF Symbol ever fails to load, fall back to text so it's never invisible.
        button.title = (img == nil) ? "Transcribe" : ""
    }

    private func openSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 360, height: 300),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            win.title = "Transcribe Settings"
            win.isReleasedWhenClosed = false
            win.contentViewController = NSHostingController(rootView: SettingsView().environmentObject(model))
            win.center()
            settingsWindow = win
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
