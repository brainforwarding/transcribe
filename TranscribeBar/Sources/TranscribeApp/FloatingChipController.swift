import AppKit
import SwiftUI

/// Keeps the panel exactly the size of the chip; the bottom-left corner stays put.
private final class FittingHostingView<Content: View>: NSHostingView<Content> {
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in self?.fitWindow() }
    }
    func fitWindow() {
        guard let window else { return }
        let size = fittingSize
        guard size.width > 0, size.height > 0, window.frame.size != size else { return }
        window.setContentSize(size)
    }
}

private final class NonactivatingChipPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A small HUD which leaves the originating app and text field focused.
@MainActor
final class FloatingChipController {
    private var panel: NSPanel?
    private var screenObserver: NSObjectProtocol?

    func show<V: View>(_ view: V) {
        let panel = self.panel ?? makePanel()
        let host = FittingHostingView(rootView: view)
        panel.setContentSize(host.fittingSize)
        panel.contentView = host
        place(panel)
        panel.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    private func makePanel() -> NSPanel {
        let panel = NonactivatingChipPanel(contentRect: NSRect(x: 0, y: 0, width: 120, height: 26),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        self.panel = panel
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in if let panel = self?.panel { self?.place(panel) } }
        }
        return panel
    }

    private func place(_ panel: NSPanel) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: frame.minX + 20, y: frame.minY + 20))
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }
}
