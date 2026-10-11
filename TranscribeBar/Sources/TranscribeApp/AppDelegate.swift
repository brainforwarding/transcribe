import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let model = AppModel()
    private let shortcuts = ShortcutService()
    private let chip = FloatingChipController()
    private var statusItem: NSStatusItem!
    private var libraryWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var showingChip = false
    private var shownWidth: CGFloat = 0
    private var pasteShortcutEnabled: Bool?
    private var quitting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        DesignSystem.registerFonts()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        add("Start dictation    ⌥ ⌥", #selector(toggleDictation), symbol: "mic", to: menu, tag: 1)
        add("Start meeting…", #selector(openMeetings), symbol: "video", to: menu)
        add("Paste last transcript    ⌥ ⇧ V", #selector(pasteLast), symbol: "doc.on.clipboard", to: menu, tag: 3)
        menu.addItem(.separator())
        add("Open Transcribe", #selector(openLibrary), symbol: "waveform", to: menu)
        add("Settings…", #selector(openSettings), symbol: "gearshape", to: menu)
        menu.addItem(.separator())
        add("Quit Transcribe", #selector(quit), symbol: "power", to: menu)
        statusItem.menu = menu

        model.showLibrary = { [weak self] in self?.openLibrary() }
        model.showSettings = { [weak self] in self?.openSettings() }
        model.retryShortcuts = { [weak self] in self?.shortcuts.start() }
        shortcuts.dictationContext = { [weak self] in
            guard let self else { return .disabled }
            if self.model.activeKind == .dictation,
               self.model.phase == .starting || self.model.phase == .recording,
               let id = self.model.activeSessionID { return .capturing(id) }
            return self.model.isBusy ? .disabled : .idle
        }
        shortcuts.onStartDictation = { [weak self] in self?.model.startDictation() }
        shortcuts.onStopDictation = { [weak self] id in
            guard let self, self.model.activeSessionID == id,
                  self.model.activeKind == .dictation,
                  self.model.phase == .starting || self.model.phase == .recording else { return }
            self.model.finishRecording()
        }
        shortcuts.onCancel = { [weak self] in
            guard let self else { return }
            if self.model.activeKind == .meeting { self.model.chipVisible = false }
            else { self.model.cancelDictation() }
        }
        shortcuts.onPasteLast = { [weak self] in self?.model.pasteLast() }
        shortcuts.onAvailabilityChanged = { [weak self] available in self?.model.shortcutAvailable = available }
        shortcuts.start()
        model.objectWillChange
            .sink { [weak self] in
                // @Published emits before the assignment. Read committed state on the next turn.
                DispatchQueue.main.async { self?.refreshNativeState() }
            }.store(in: &cancellables)
        refreshNativeState()
        if !model.hasKey { openLibrary() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        shortcuts.start()
        Task { await model.refreshPermissions() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openLibrary()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitting else { return .terminateLater }
        quitting = true
        Task {
            await model.prepareToQuit()
            shortcuts.stop()
            chip.hide()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.item(withTag: 3)?.title = model.pasteLastShortcutEnabled
            ? "Paste last transcript    ⌥ ⇧ V" : "Paste last transcript"
        guard let dictation = menu.item(withTag: 1) else { return }
        if model.activeKind == .dictation, model.isBusy {
            let canFinish = model.phase == .recording || model.phase == .starting
            dictation.title = canFinish ? "Finish dictation    ⌥" : "Transcribing…"
            dictation.image = menuImage(canFinish ? "stop.fill" : "ellipsis.circle")
            dictation.isEnabled = canFinish
        } else {
            dictation.title = "Start dictation    ⌥ ⌥"
            dictation.image = menuImage("mic")
            dictation.isEnabled = !model.isBusy
        }
    }

    private func refreshNativeState() {
        if pasteShortcutEnabled != model.pasteLastShortcutEnabled {
            shortcuts.setPasteLastShortcut(enabled: model.pasteLastShortcutEnabled)
            pasteShortcutEnabled = model.pasteLastShortcutEnabled
        }
        shortcuts.consumesEscape = model.activeKind == .dictation &&
            [.starting, .recording, .stopping, .transcribing].contains(model.phase)
        shortcuts.observesEscapeDuringMeeting = model.activeKind == .meeting && model.isBusy
        NSApp.appearance = model.appearance == "dark" ? NSAppearance(named: .darkAqua)
            : model.appearance == "light" ? NSAppearance(named: .aqua) : nil
        if model.chipVisible, model.chipState != .hidden {
            if !showingChip || shownWidth != model.chipWidth {
                chip.show(ChipView(model: model), width: model.chipWidth)
                showingChip = true
                shownWidth = model.chipWidth
            }
        } else if showingChip {
            chip.hide()
            showingChip = false
        }
        let name = model.phase == .recording ? "record.circle.fill"
            : model.phase == .transcribing || model.phase == .stopping ? "ellipsis.circle" : "waveform"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Transcribe")
        image?.isTemplate = true
        statusItem?.button?.image = image
        statusItem?.button?.title = image == nil ? "Transcribe" : ""
    }

    private func menuImage(_ symbol: String) -> NSImage? {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        image?.size = NSSize(width: 16, height: 16)
        image?.isTemplate = true
        return image
    }

    private func add(_ title: String, _ action: Selector, symbol: String, to menu: NSMenu, tag: Int = 0) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.tag = tag
        item.indentationLevel = 0
        item.image = menuImage(symbol)
        menu.addItem(item)
    }

    @objc private func toggleDictation() { model.toggleDictation() }
    @objc private func pasteLast() { model.pasteLast() }
    @objc private func openMeetings() { model.openMeetings() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openLibrary() {
        if libraryWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Transcribe"
            window.minSize = NSSize(width: 860, height: 600)
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: ContentView().environmentObject(model))
            window.setFrameAutosaveName("TranscribeLibrary")
            window.center()
            libraryWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        libraryWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func openSettings() {
        model.sidebar = .settings
        model.selectedRecordID = nil
        model.searchText = ""
        model.meetingSetupPresented = false
        openLibrary()
    }
}
