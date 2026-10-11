import Foundation
import AVFoundation
import CoreMedia

@available(macOS 13.0, *)
public final class CaptureController: @unchecked Sendable {
    public let systemURL: URL
    public let micURL: URL
    private let directory: URL
    private let epoch: Double
    private let system: SystemAudioCapture?
    private let mic: MicCapture
    private let micUniqueID: String?
    private let lock = NSLock()
    private var stopped = false
    private var started = false
    private var issues: [TranscriptionIssue] = []
    private var systemUnavailable = false
    private let previewQueue = DispatchQueue(label: "transcribe.preview.mix", qos: .utility)
    private var nextPreviewOffset = 0.0
    public var onLog: (@Sendable (String) -> Void)?
    public var onLevel: (@Sendable (Source, Double) -> Void)?
    public var onHealth: (@Sendable (CaptureHealth) -> Void)?
    public var onPreviewWindow: (@Sendable (PreviewWindow) -> Void)?
    public var onAudioFrame: (@Sendable (CapturedAudioFrame) -> Void)?

    public init(outDir: URL, micUniqueID: String?, micOnly: Bool = false) {
        directory = outDir
        epoch = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        systemURL = outDir.appendingPathComponent("system_part_00000.wav")
        micURL = outDir.appendingPathComponent("mic_part_00000.wav")
        system = micOnly ? nil : SystemAudioCapture(outputURL: systemURL, epoch: epoch)
        mic = MicCapture(outputURL: micURL, epoch: epoch)
        self.micUniqueID = micUniqueID
        mic.onLevel = { [weak self] in self?.onLevel?(.mic, $0) }
        system?.onLevel = { [weak self] in self?.onLevel?(.system, $0) }
        mic.onHealth = { [weak self] in self?.handleHealth($0) }
        system?.onHealth = { [weak self] in self?.handleHealth($0) }
        mic.onPart = { [weak self] _ in self?.schedulePreview() }
        system?.onPart = { [weak self] _ in self?.schedulePreview() }
        mic.onAudioFrame = { [weak self] in self?.onAudioFrame?($0) }
        system?.onAudioFrame = { [weak self] in self?.onAudioFrame?($0) }
        mic.onLog = { [weak self] in self?.onLog?($0) }
        system?.onLog = { [weak self] in self?.onLog?($0) }
    }
    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    private func handleHealth(_ health: CaptureHealth) {
        if health.state == .interrupted || health.state == .unavailable {
            lock.lock()
            let issue = TranscriptionIssue(source: health.source, userMessage: health.message ?? "Audio capture was interrupted.", retryable: false)
            if !issues.contains(issue) { issues.append(issue) }
            if health.source == .system { systemUnavailable = true }
            lock.unlock()
        } else if health.source == .system && health.state == .silent && health.message == "No Mac audio has arrived yet." {
            lock.withLock { systemUnavailable = true }
            schedulePreview()
        } else if health.source == .system && (health.state == .active || (health.state == .silent && health.message == nil)) {
            lock.lock(); systemUnavailable = false; lock.unlock()
        }
        onHealth?(health)
    }
    public func start() async throws {
        let mayStart = lock.withLock { () -> Bool in
            guard !stopped, !started else { return false }; started = true; return true
        }
        guard mayStart else { throw CancellationError() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["epoch": epoch])
            .write(to: directory.appendingPathComponent("capture.json"), options: .atomic)
        // The microphone starts independently; system silence or a permission failure
        // cannot prevent the user's voice from being recorded.
        async let microphone: String = Task.detached { [mic, micUniqueID] in try mic.start(uniqueID: micUniqueID) }.value
        async let macAudio: Void = startSystemIfAvailable()
        do {
            _ = try await microphone
            await macAudio
            guard !isStopped else { throw CancellationError() }
        } catch {
            _ = await stop()
            throw error
        }
    }
    private func startSystemIfAvailable() async {
        guard let system, !isStopped else { return }
        do { try await system.start() }
        catch {
            if !isStopped { handleHealth(CaptureHealth(source: .system, state: .unavailable,
                message: "Mac audio is unavailable. Your microphone is still recording.")) }
        }
    }
    public func retrySystemAudio() async throws {
        guard let system, !isStopped else { throw CancellationError() }
        try await system.restart(shouldContinue: { [weak self] in self?.isStopped == false })
        if isStopped { _ = await system.stop(); throw CancellationError() }
    }
    public struct Result: Sendable {
        public let systemURL: URL?
        public let micURL: URL
        public let micOffset: Double
        public let systemOffset: Double
        public let systemSummary: SystemAudioCapture.Summary?
        public let tracks: [SessionAudioTrack]
        public let issues: [TranscriptionIssue]
    }
    @discardableResult
    public func stop() async -> Result {
        lock.withLock { stopped = true }
        async let sys = system?.stop()
        await mic.stop()
        let systemSummary = await sys
        let micSpans = mic.capturedSpans
        let systemSpans = system?.capturedSpans ?? []
        var tracks = [SessionAudioTrack(source: .mic, spans: micSpans)]
        if system != nil { tracks.append(SessionAudioTrack(source: .system, spans: systemSpans)) }
        let allIssues = lock.withLock { issues }
        return Result(systemURL: system == nil ? nil : (systemSpans.first?.url ?? systemURL),
                      micURL: micSpans.first?.url ?? micURL,
                      micOffset: micSpans.first?.offset ?? 0,
                      systemOffset: systemSpans.first?.offset ?? 0,
                      systemSummary: systemSummary, tracks: tracks, issues: allIssues)
    }
    public static func recoverTracks(in directory: URL) -> [SessionAudioTrack] { recoverSessionAudioTracks(in: directory) }
    private func schedulePreview() {
        guard onPreviewWindow != nil, !isStopped else { return }
        previewQueue.async { [weak self] in self?.preparePreview() }
    }
    private func preparePreview() {
        guard let callback = onPreviewWindow, !isStopped else { return }
        let micSpans = mic.closedSpans
        let systemSpans = system?.closedSpans ?? []
        guard let micEnd = micSpans.last.map({ $0.offset + $0.duration }) else { return }
        let unavailable = lock.withLock { systemUnavailable }
        let end: Double
        if system != nil && !unavailable {
            guard let sysEnd = systemSpans.last.map({ $0.offset + $0.duration }) else { return }
            end = min(micEnd, sysEnd)
        } else { end = micEnd }
        guard end >= nextPreviewOffset + 45 else { return }
        // A serial mixer emits only finalized windows. The coordinator drops windows
        // under network load and owns the provider budget; capture never waits on HTTP.
        let offset = nextPreviewOffset
        nextPreviewOffset += 45
        do {
            let previews = directory.appendingPathComponent("previews", isDirectory: true)
            try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
            let raw = previews.appendingPathComponent("window-\(Int(offset)).wav")
            try writeAlignedAudio(tracks: [SessionAudioTrack(source: .mic, spans: micSpans),
                                          SessionAudioTrack(source: .system, spans: systemSpans)],
                                  to: raw, start: offset, duration: 45, mix: true)
            if !isStopped { callback(PreviewWindow(url: raw, offset: offset, duration: 45)) }
        } catch { onLog?("Transcript preview could not be prepared. Capture continues.") }
    }
}
