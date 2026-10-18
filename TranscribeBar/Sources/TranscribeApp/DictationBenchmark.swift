#if TRANSCRIBE_DICTATION_BENCHMARK
import Foundation
import AVFoundation
import TranscribeCore

/// Benchmark-only transport. Production prompt and validation stay unchanged;
/// this can opt a single test request into Fast processing and records the tier
/// actually returned, without saving credentials or response bodies.
private final class EditorBenchmarkProtocol: URLProtocol {
    static var fast = false
    static var groqModel: String?
    static var returnedTier = "unspecified"
    static var usage: [String: Any] = [:]
    private var networkTask: Task<Void, Never>?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var forwarded = request
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream, body.isEmpty {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 8192)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        if var payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
            payload.removeValue(forKey: "service_tier")
            if Self.fast { payload["service_tier"] = "fast" }
            if let model = Self.groqModel {
                payload["model"] = model
                payload["reasoning_effort"] = "low"
                payload["include_reasoning"] = false
            }
            forwarded.httpBodyStream = nil
            forwarded.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        } else { forwarded.httpBodyStream = nil; forwarded.httpBody = body }
        networkTask = Task {
            do {
                let (data, response) = try await URLSession.shared.data(for: forwarded)
                if let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    Self.returnedTier = payload["service_tier"] as? String ?? "unspecified"
                    Self.usage = payload["usage"] as? [String: Any] ?? [:]
                }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    override func stopLoading() { networkTask?.cancel() }
}

/// Compile-only evaluation entry point. No AppModel, owner history, capture,
/// shortcuts, clipboard, permission prompts, credential writes or analytics.
private actor BenchmarkLedger {
    var turns: [MeetingTurn] = []
    var firstDraft: Double?
    var issues: [String] = []
    func issue(_ value: TranscriptionIssue) { issues.append(value.failureKind?.rawValue ?? "unclassified") }
    func save(_ value: [MeetingTurn]) { turns = value }
    func draft(_ value: LiveMeetingDraft) {
        if firstDraft == nil, !value.text.isEmpty { firstDraft = ProcessInfo.processInfo.systemUptime }
    }
}

@main struct DictationBenchmark {
    static func main() async {
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
            reason: "Dictation boundary evaluation")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let args = CommandLine.arguments
        guard args.count == 4, ["standard", "live", "committed", "legacy", "assemble-record", "format-record", "fast-assemble-record", "recover-record", "groq20-assemble-record", "groq120-assemble-record"].contains(args[3]) else {
            print("Usage: benchmark-app input report-directory standard|live|committed|legacy|assemble-record|format-record|fast-assemble-record")
            exit(2)
        }
        let provider = UserDefaults.standard.string(forKey: "connectionProvider")
            .flatMap(ConnectionProvider.init(rawValue:)) ?? .team
        // Uses the configured app identity and provider without requesting broader access.
        let groq = args[3].hasPrefix("groq")
        let suppliedKey = groq ? String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        guard let key = groq ? suppliedKey : Keychain.get(for: provider), !key.isEmpty else {
            print("Benchmark credential unavailable without interaction. No credentials were changed.")
            exit(3)
        }
        let config = OpenAIConfig(baseURL: groq ? URL(string: "https://api.groq.com/openai/v1")! : provider.baseURL, authValue: "Bearer \(key)")
        let audioURL = URL(fileURLWithPath: args[1]), directory = URL(fileURLWithPath: args[2])
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            if args[3].hasSuffix("-record") {
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                var record = try decoder.decode(SessionRecord.self, from: Data(contentsOf: audioURL))
                var recoveredText: String?
                if args[3] == "recover-record" {
                    let result = try await transcribeFinal(tracks: record.tracks, kind: .dictation,
                        chunkDir: directory.appendingPathComponent("fallback"), config: config)
                    guard result.complete else { throw ProviderError.unavailable }
                    recoveredText = result.text
                }
                let raw = record.meetingTurns.sorted { $0.start < $1.start }.map(\.text).joined(separator: " ")
                EditorBenchmarkProtocol.fast = args[3] == "fast-assemble-record"
                EditorBenchmarkProtocol.groqModel = groq ? (args[3].hasPrefix("groq20-") ? "openai/gpt-oss-20b" : "openai/gpt-oss-120b") : nil
                let settings = URLSessionConfiguration.ephemeral
                settings.protocolClasses = [EditorBenchmarkProtocol.self]
                let editorSession = URLSession(configuration: settings)
                defer { editorSession.invalidateAndCancel() }
                let started = ProcessInfo.processInfo.systemUptime
                let result = args[3] == "format-record" || recoveredText != nil
                    ? try await formatDictation(recoveredText ?? raw, config: config, session: editorSession)
                    : try await assembleDictation(record.meetingTurns, config: config, session: editorSession)
                let seconds = ProcessInfo.processInfo.systemUptime - started
                var report: [String: Any] = ["mode": args[3], "seconds": seconds, "chunks": record.meetingTurns.count,
                    "serviceTier": EditorBenchmarkProtocol.returnedTier, "usage": EditorBenchmarkProtocol.usage,
                    "text": result.text, "failure": result.failure?.rawValue ?? "none"]
                report["turns"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record.meetingTurns))
                let path = directory.appendingPathComponent("report.json")
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: path, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
                print(String(format: "%@: %d chunks, %.3fs, tier %@, failure %@", args[3], record.meetingTurns.count, seconds, EditorBenchmarkProtocol.returnedTier, result.failure?.rawValue ?? "none"))
                return
            }
            let audio = try AVAudioFile(forReading: audioURL)
            guard audio.processingFormat.sampleRate == 16_000, audio.processingFormat.channelCount == 1,
                  audio.length > 0, audio.length <= 16_000 * 300,
                  let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length))
            else { throw ProviderError.configuration }
            try audio.read(into: buffer)
            guard let samples = buffer.floatChannelData?[0] else { throw ProviderError.configuration }
            let pcm = Array(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
            let duration = Double(pcm.count) / 16_000
            let tracks = [SessionAudioTrack(source: .mic, spans: [.init(url: audioURL, offset: 0, duration: duration)])]
            let started = ProcessInfo.processInfo.systemUptime
            var stopped = started, raw = "", usedRecovery = false, liveCoverage = 0.0
            var firstDraft: Double?
            var liveIssues: [String] = []
            var finalTurns: [MeetingTurn] = []
            if args[3] == "standard" {
                let result = try await transcribeFinal(tracks: tracks, kind: .dictation,
                    chunkDir: directory.appendingPathComponent("chunks"), config: config)
                guard result.complete else { throw ProviderError.unavailable }
                raw = result.text
            } else {
                let ledger = BenchmarkLedger()
                let live = LiveMeetingController(realtimeURL: provider.realtimeURL, config: config, sources: [.mic],
                    onPersist: { await ledger.save($0) }, onDraft: { value in Task { await ledger.draft(value) } },
                    onIssue: { value in Task { await ledger.issue(value) } }, finishTimeout: 2,
                    model: args[3] == "live" ? .live : .committed, pauseAwareDictation: args[3] != "legacy")
                await live.start()
                let replayStarted = ProcessInfo.processInfo.systemUptime
                for offset in stride(from: 0, to: pcm.count, by: 800) {
                    let end = min(pcm.count, offset + 800), slice = Array(pcm[offset..<end])
                    let rms = sqrt(slice.reduce(0) { $0 + Double($1 * $1) } / Double(slice.count))
                    let bytes = slice.withUnsafeBytes { Data($0) }
                    let deadline = replayStarted + Double(end) / 16_000
                    let wait = deadline - ProcessInfo.processInfo.systemUptime
                    if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                    live.offer(.init(source: .mic, offset: Double(offset) / 16_000, pcmFloat32: bytes, rms: rms))
                }
                stopped = ProcessInfo.processInfo.systemUptime
                var turns = await live.finish()
                liveCoverage = turns.filter { $0.state == .confirmed }.reduce(0) { $0 + $1.end - $1.start }
                firstDraft = await ledger.firstDraft.map { $0 - started }
                liveIssues = await ledger.issues
                usedRecovery = !uncoveredMeetingAudio(tracks: tracks, turns: turns, includePending: false).isEmpty
                if usedRecovery {
                    if args[3] == "committed" {
                        let result = try await transcribeFinal(tracks: tracks, kind: .dictation,
                            chunkDir: directory.appendingPathComponent("fallback"), config: config)
                        guard result.complete else { throw ProviderError.unavailable }
                        raw = result.text
                    } else {
                        turns = try await recoverMeetingTurns(tracks: tracks, turns: turns,
                            directory: directory.appendingPathComponent("recovery"), config: config, onPersist: { await ledger.save($0) })
                    }
                }
                guard usedRecovery && args[3] == "committed" || uncoveredMeetingAudio(tracks: tracks, turns: turns, includePending: false).isEmpty else { throw ProviderError.unavailable }
                finalTurns = turns
                if !(usedRecovery && args[3] == "committed") {
                    raw = turns.filter { $0.state == .confirmed }.sorted { $0.start < $1.start }.map(\.text).joined(separator: " ")
                }
            }
            let recognized = ProcessInfo.processInfo.systemUptime
            let formatted = args[3] == "committed" && !usedRecovery
                ? try await assembleDictation(finalTurns, config: config)
                : try await formatDictation(raw, config: config)
            let ready = ProcessInfo.processInfo.systemUptime
            var report: [String: Any] = ["mode": args[3], "provider": provider.rawValue,
                "audioSeconds": duration, "stopToTranscript": recognized - stopped,
                "formattingSeconds": ready - recognized, "stopToReady": ready - stopped,
                "usedRecovery": usedRecovery, "liveConfirmedSeconds": liveCoverage,
                "rawTranscript": raw, "formattedTranscript": formatted.text, "liveIssueCategories": liveIssues]
            let turnEncoder = JSONEncoder()
            report["turns"] = try JSONSerialization.jsonObject(with: turnEncoder.encode(finalTurns))
            if args[3] != "standard" { report["replayWallSeconds"] = stopped - started }
            if let firstDraft { report["firstDraftFromStart"] = firstDraft }
            if let failure = formatted.failure { report["formattingFailure"] = failure.rawValue }
            let reportURL = directory.appendingPathComponent("report.json")
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: reportURL.path)
            print(String(format: "%@ stop-to-text %.3fs formatting %.3fs ready %.3fs recovery %@", args[3],
                         recognized - stopped, ready - recognized, ready - stopped, usedRecovery ? "yes" : "no"))
        } catch {
            let category = (error as? ProviderError)?.failureKind?.rawValue ?? "localBenchmarkFailure"
            print("Benchmark did not complete: \(category). Input audio was preserved.")
            exit(1)
        }
    }
}
#endif
