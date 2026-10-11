import SwiftUI
import AppKit

/// Content growth alone never changes whether the reader wants to follow.
struct LiveTranscriptFollowPolicy {
    enum Motion { case none, awayFromBottom, towardBottom }
    private(set) var followsLatest = true

    mutating func observe(bottomGap: Double, motion: Motion) {
        switch motion {
        case .none: break
        case .awayFromBottom: followsLatest = false
        case .towardBottom:
            if bottomGap.isFinite && bottomGap <= 32 { followsLatest = true }
        }
    }
}

@MainActor
final class LiveTranscriptFollower: ObservableObject {
    @Published private(set) var scrollPulse = 0
    private var policy = LiveTranscriptFollowPolicy()
    private var pending: Task<Void, Never>?
    private var programmaticUntil: TimeInterval = 0
    var scrollingProgrammatically: Bool { ProcessInfo.processInfo.systemUptime < programmaticUntil }

    func contentChanged() {
        guard policy.followsLatest, pending == nil else { return }
        pending = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            guard let self else { return }
            self.pending = nil
            guard self.policy.followsLatest else { return }
            self.programmaticUntil = ProcessInfo.processInfo.systemUptime + 0.45
            self.scrollPulse += 1
        }
    }

    func userInteracted(scrollingUp: Bool) {
        if scrollingUp {
            // The last animation may still move toward bottom after this input.
            // Keep its suppression deadline while immediately pausing follow.
            policy.observe(bottomGap: .infinity, motion: .awayFromBottom)
            pending?.cancel(); pending = nil
        } else { programmaticUntil = 0 }
    }
    func observe(bottomGap: Double, motion: LiveTranscriptFollowPolicy.Motion) {
        guard !scrollingProgrammatically else { return }
        let wasFollowing = policy.followsLatest
        policy.observe(bottomGap: bottomGap, motion: motion)
        if !policy.followsLatest { pending?.cancel(); pending = nil }
        else if !wasFollowing { contentChanged() }
    }
    func stop() { pending?.cancel(); pending = nil }
}

/// macOS 13 has no SwiftUI scroll-position API. This observes its existing
/// native scroll view; it does not replace the SwiftUI content or handle input.
struct LiveTranscriptScrollProbe: NSViewRepresentable {
    let follower: LiveTranscriptFollower
    func makeNSView(context: Context) -> Probe { Probe(follower: follower) }
    func updateNSView(_ view: Probe, context: Context) { view.connect() }

    final class Probe: NSView {
        private let follower: LiveTranscriptFollower
        private weak var scrollView: NSScrollView?
        private var observers: [NSObjectProtocol] = []
        private var eventMonitor: Any?
        private var userInputUntil: TimeInterval = 0
        private var previous: (gap: Double, contentHeight: CGFloat, viewportHeight: CGFloat)?

        init(follower: LiveTranscriptFollower) { self.follower = follower; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); connect() }
        func connect() {
            guard scrollView == nil else { return }
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }
        private func attach() {
            guard scrollView == nil, let scroll = enclosingScrollView, let document = scroll.documentView else { return }
            scrollView = scroll
            scroll.contentView.postsBoundsChangedNotifications = true
            document.postsFrameChangedNotifications = true
            for (name, object) in [(NSView.boundsDidChangeNotification, scroll.contentView), (NSView.frameDidChangeNotification, document)] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in self?.measure() })
            }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .leftMouseDragged, .keyDown]) { [weak self] event in
                self?.observeInput(event)
                return event
            }
            measure()
        }
        private func observeInput(_ event: NSEvent) {
            guard let scroll = scrollView, event.window === scroll.window else { return }
            if event.type == .keyDown {
                guard [116, 121, 115, 119, 125, 126].contains(event.keyCode),
                      let responder = scroll.window?.firstResponder as? NSView,
                      responder.isDescendant(of: scroll) else { return }
            } else {
                guard scroll.bounds.contains(scroll.convert(event.locationInWindow, from: nil)) else { return }
            }
            userInputUntil = ProcessInfo.processInfo.systemUptime + 0.4
            let scrollingUp = event.type == .scrollWheel ? event.scrollingDeltaY > 0
                : event.type == .keyDown && [116, 115, 126].contains(event.keyCode)
            if event.type == .keyDown || (event.type == .scrollWheel && event.scrollingDeltaY != 0) {
                follower.userInteracted(scrollingUp: scrollingUp)
            }
        }
        private func measure() {
            guard let scroll = scrollView, let document = scroll.documentView else { return }
            let visible = scroll.contentView.bounds
            let gap = max(0, Double(document.isFlipped ? document.bounds.maxY - visible.maxY : visible.minY - document.bounds.minY))
            defer { previous = (gap, document.bounds.height, visible.height) }
            guard let previous else { return }
            // Bounds changes from new paragraphs, resize and our own animation
            // are not scroll intent. A wheel, scrollbar or focused navigation key is.
            guard ProcessInfo.processInfo.systemUptime < userInputUntil,
                  abs(previous.contentHeight - document.bounds.height) < 0.5,
                  abs(previous.viewportHeight - visible.height) < 0.5 else { return }
            let movement = gap - previous.gap
            if abs(movement) > 0.5 {
                follower.observe(bottomGap: gap, motion: movement > 0 ? .awayFromBottom : .towardBottom)
            }
        }
        deinit {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        }
    }
}
