import Foundation

/// Arrival of buffers, including silent ones, measures capture continuity.
/// Signal level does not tell us whether a device is still delivering audio.
struct AudioLiveness {
    enum Failure: Equatable { case noBuffers, stalled }
    private(set) var startedAt: Double?
    private(set) var lastBufferAt: Double?
    mutating func start(at time: Double) { startedAt = time; lastBufferAt = nil }
    mutating func received(at time: Double) { lastBufferAt = time }
    func failure(at time: Double, tolerance: Double = 3) -> Failure? {
        guard let startedAt else { return nil }
        if let lastBufferAt { return time - lastBufferAt > tolerance ? .stalled : nil }
        return time - startedAt > tolerance ? .noBuffers : nil
    }
}

func captureHostSeconds() -> Double { ProcessInfo.processInfo.systemUptime }
