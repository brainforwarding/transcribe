import Foundation

/// Restarts Mac audio at once and then every `interval` until its buffers arrive again or capture
/// stops. One loop at a time, whichever signals fire. While down, the app keeps seeing the failure
/// that started the loop: each attempt's "Starting" and first-buffer wait are hidden.
final class SystemAudioRecovery: @unchecked Sendable {
    private let lock = NSLock()
    private let interval: UInt64
    private let attempt: @Sendable () async -> Void
    private var loop: Task<Void, Never>?
    private var down = false
    private var generation = 0
    private var stopped = false
    init(interval: TimeInterval = 5, attempt: @escaping @Sendable () async -> Void) {
        self.interval = UInt64(max(0.001, interval) * 1_000_000_000); self.attempt = attempt
    }
    var isDown: Bool { lock.withLock { down } }
    /// False when a loop already runs or capture has stopped.
    @discardableResult func begin() -> Bool {
        lock.withLock {
            guard !stopped, !down else { return false }
            down = true; generation += 1
            // A loop that just recovered may still be finishing its attempt; never overlap two.
            let previous = loop, current = generation
            loop = Task { [weak self] in await previous?.value; await self?.run(current) }
            return true
        }
    }
    private func running(_ current: Int) -> Bool { lock.withLock { down && !stopped && generation == current } }
    private func run(_ current: Int) async {
        while running(current) {
            // Detached from the loop's cancellation: a cancelled ScreenCaptureKit start could leave a
            // running stream without its watchdog. Stop is handled by the attempt itself.
            await Task { [attempt] in await attempt() }.value
            guard running(current) else { return }
            try? await Task.sleep(nanoseconds: interval)
        }
    }
    /// What the app sees of a Mac audio health report. Arriving buffers end the loop.
    func filter(_ health: CaptureHealth) -> CaptureHealth? {
        lock.withLock {
            guard down else { return health }
            switch health.state {
            case .active, .silent where health.message == nil:
                down = false; loop?.cancel(); return health
            case .starting, .silent: return nil
            default: return health
            }
        }
    }
    /// Cancels the wait and returns once no attempt can still be running.
    func stop() async {
        let task = lock.withLock { () -> Task<Void, Never>? in stopped = true; down = false; return loop }
        task?.cancel(); await task?.value
    }
}
