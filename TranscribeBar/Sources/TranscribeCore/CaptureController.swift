import Foundation
import AVFoundation
import CoreMedia

/// Runs the system (SCK) + mic (AVCaptureSession) captures together. The mic is started on
/// the system tap's first audio buffer (in-process), bounding the inter-track gap; the final
/// offset is derived sample-accurately from the two first-buffer PTS values on the host clock.
///
/// `micOnly: true` skips ScreenCaptureKit entirely — no SystemAudioCapture is created, so no
/// Screen Recording permission is ever touched. The mic starts directly and the result has
/// no system track (offset 0; the single track IS the timeline).
@available(macOS 13.0, *)
public final class CaptureController: @unchecked Sendable {

    public let systemURL: URL
    public let micURL: URL
    private let system: SystemAudioCapture?
    private let mic: MicCapture
    private let micUniqueID: String?
    private var micStarted = false
    private let lock = NSLock()

    public var onLog: (@Sendable (String) -> Void)? {
        didSet { system?.onLog = onLog; mic.onLog = onLog }
    }

    public init(outDir: URL, micUniqueID: String?, micOnly: Bool = false) {
        self.systemURL = outDir.appendingPathComponent("system.wav")
        self.micURL = outDir.appendingPathComponent("mic.caf")
        self.system = micOnly ? nil : SystemAudioCapture(outputURL: systemURL)
        self.mic = MicCapture(outputURL: micURL)
        self.micUniqueID = micUniqueID
    }

    public func start() async throws {
        guard let system else {
            // Mic-only: no ScreenCaptureKit setup, no permission check — just the mic.
            _ = try mic.start(uniqueID: micUniqueID)
            return
        }
        system.onFirstBuffer = { [weak self] in
            guard let self else { return }
            self.lock.lock(); let go = !self.micStarted; self.micStarted = true; self.lock.unlock()
            guard go else { return }
            do { _ = try self.mic.start(uniqueID: self.micUniqueID) }
            catch { self.onLog?("mic start failed: \(error)") }
        }
        try await system.start()
    }

    public struct Result: Sendable {
        public let systemURL: URL?       // nil in mic-only mode
        public let micURL: URL
        public let micOffset: Double
        public let systemSummary: SystemAudioCapture.Summary?
    }

    @discardableResult
    public func stop() async -> Result {
        let sys = await system?.stop()
        await mic.stop()
        var offset = 0.0
        if let s = system?.firstSamplePTS, let m = mic.firstSamplePTS {
            offset = max(0, CMTimeGetSeconds(CMTimeSubtract(m, s)))
        }
        return Result(systemURL: system == nil ? nil : systemURL,
                      micURL: micURL, micOffset: offset, systemSummary: sys)
    }
}
