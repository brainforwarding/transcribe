import Foundation
import AVFoundation

/// Replay retained canonical audio through the same continuous model as capture.
/// File rotation is storage only: adjacent files share one open transcription item.
public func transcribeContinuousDictation(tracks: [SessionAudioTrack], languages: [String] = [],
    keywords: [String] = [], config: OpenAIConfig,
    socketFactory: LiveMeetingController.SocketFactory? = nil) async throws -> FinalTranscription {
    guard let track = tracks.first(where: { $0.source == .mic }), !track.spans.isEmpty else {
        throw ProviderError.invalidResponse
    }
    var components = URLComponents(url: config.baseURL.appendingPathComponent("realtime"), resolvingAgainstBaseURL: false)!
    components.scheme = components.scheme == "http" ? "ws" : "wss"
    components.queryItems = [URLQueryItem(name: "intent", value: "transcription")]
    guard let endpoint = components.url else { throw ProviderError.invalidResponse }
    let live = LiveMeetingController(realtimeURL: endpoint, config: config, sources: [.mic],
        languages: languages, keywords: keywords, onPersist: { _ in }, socketFactory: socketFactory,
        continuousDictation: true)
    await live.start()
    do {
        for span in track.spans.sorted(by: { $0.offset < $1.offset }) {
            try Task.checkCancellation()
            try validateCapturedMeetingInterval(track: track, start: span.offset, end: span.offset + span.duration)
            let file = try AVAudioFile(forReading: span.url,
                commonFormat: .pcmFormatFloat32, interleaved: false)
            let sampleCount = AVAudioFramePosition((span.duration * 16_000).rounded())
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1_600) else {
                throw ProviderError.cacheWrite
            }
            var cursor: AVAudioFramePosition = 0
            while cursor < sampleCount {
                try Task.checkCancellation()
                try file.read(into: buffer, frameCount: AVAudioFrameCount(min(1_600, sampleCount - cursor)))
                guard buffer.frameLength > 0, let samples = buffer.floatChannelData?[0] else { throw ProviderError.cacheWrite }
                let duration = Double(buffer.frameLength) / 16_000
                let bytes = Data(bytes: samples, count: Int(buffer.frameLength) * MemoryLayout<Float>.size)
                live.offer(.init(source: .mic, offset: span.offset + Double(cursor) / 16_000,
                    pcmFloat32: bytes, rms: 1))
                cursor += AVAudioFramePosition(buffer.frameLength)
                // Preserve realtime pacing and bound memory, including through Team.
                try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            }
        }
        let turns = await live.finish()
        try Task.checkCancellation()
        let missing = uncoveredMeetingAudio(tracks: [track], turns: turns, includePending: false)
        let issues = missing.map { gap in TranscriptionIssue(source: .mic,
            userMessage: "Some dictated words are missing. The saved audio can be retried.", retryable: true,
            failureKind: turns.first(where: { $0.state != .confirmed && $0.start < gap.end && $0.end > gap.start })?.failureKind ?? .unavailable) }
        return FinalTranscription(text: turns.filter { $0.state == .confirmed }.sorted { $0.start < $1.start }
            .map(\.text).joined(separator: " "), segments: [], complete: missing.isEmpty, issues: issues)
    } catch {
        _ = await live.cancel()
        throw error
    }
}
