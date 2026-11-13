import Foundation
import AVFoundation

private struct LiveCheckFailure: Error { let name: String }
private func liveCheck(_ value: @autoclosure () -> Bool, _ name: String) throws { if !value() { throw LiveCheckFailure(name: name) } }
private func liveUntil(_ name: String, _ value: () -> Bool) async throws {
    for _ in 0..<2_000 {
        if value() { return }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    throw LiveCheckFailure(name: name)
}
private final class LiveFixtureSocket: LiveTranscriptionSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: CheckedContinuation<Data, Error>?
    private var inbox: [Data] = []
    private var output: [[String: Any]] = []
    private var closed = false
    private let blockConfiguration: Bool
    private let completeAtStop: Bool
    private var blockAudio: Bool
    private var failAudioAfter: Int?
    func setAudioFailure(after count: Int) { lock.withLock { failAudioAfter = count } }
    private var blockedSend: CheckedContinuation<Void, Error>?
    init(blockConfiguration: Bool = false, blockAudio: Bool = false, failAudioAfter: Int? = nil, completeAtStop: Bool = false) {
        self.completeAtStop = completeAtStop
        self.blockConfiguration = blockConfiguration; self.blockAudio = blockAudio; self.failAudioAfter = failAudioAfter
    }
    var requests: [[String: Any]] { lock.withLock { output } }
    var isClosed: Bool { lock.withLock { closed } }
    func send(_ data: Data) async throws {
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        try lock.withLock { if closed { throw ProviderError.unavailable }; output.append(json) }
        if json["type"] as? String == "input_audio_buffer.append" {
            if let limit = lock.withLock({ failAudioAfter }), appends > limit { throw ProviderError.unavailable }
            if lock.withLock({ blockAudio }) {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    lock.withLock {
                        if closed { continuation.resume(throwing: ProviderError.cancelled) }
                        else { blockedSend = continuation }
                    }
                }
            }
        }
        if completeAtStop && json["type"] as? String == "input_audio_buffer.commit" {
            push(["type": "input_audio_buffer.committed", "item_id": "replayed", "previous_item_id": NSNull()])
            push(["type": "conversation.item.input_audio_transcription.completed", "item_id": "replayed", "transcript": "Exact replayed words"])
        }
        if json["type"] as? String == "session.update" {
            if blockConfiguration {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    lock.withLock {
                        if closed { continuation.resume(throwing: ProviderError.cancelled) }
                        else { blockedSend = continuation }
                    }
                }
            }
            push(["type": "session.updated", "session": ["type": "transcription"]])
        }
    }
    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                if !inbox.isEmpty { continuation.resume(returning: inbox.removeFirst()) }
                else if closed { continuation.resume(throwing: ProviderError.cancelled) }
                else { waiting = continuation }
            }
        }
    }
    func push(_ json: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: json)
        let continuation = lock.withLock { () -> CheckedContinuation<Data, Error>? in
            guard !closed else { return nil }
            let result = waiting; waiting = nil
            if result == nil { inbox.append(data) }
            return result
        }
        continuation?.resume(returning: data)
    }
    func close() {
        let continuations = lock.withLock { closed = true; let result = (waiting, blockedSend); waiting = nil; blockedSend = nil; inbox = []; return result }
        continuations.0?.resume(throwing: ProviderError.cancelled); continuations.1?.resume(throwing: ProviderError.cancelled)
    }
    func releaseAudio() {
        let pending = lock.withLock { blockAudio = false; let pending = blockedSend; blockedSend = nil; return pending }
        pending?.resume()
    }
    var commits: Int { requests.filter { $0["type"] as? String == "input_audio_buffer.commit" }.count }
    var appends: Int { requests.filter { $0["type"] as? String == "input_audio_buffer.append" }.count }
}
private final class LiveSocketPair: @unchecked Sendable {
    let mic = LiveFixtureSocket()
    let system = LiveFixtureSocket(blockConfiguration: true)
    private let lock = NSLock()
    private var count = 0
    func next() -> LiveFixtureSocket { lock.withLock { count += 1; return count == 1 ? mic : system } }
}
private final class LiveSocketSequence: @unchecked Sendable {
    let sockets: [LiveFixtureSocket]
    private let lock = NSLock()
    private var nextIndex = 0
    var calls: Int { lock.withLock { nextIndex } }
    init(_ sockets: [LiveFixtureSocket]) { self.sockets = sockets }
    func next() throws -> LiveFixtureSocket {
        try lock.withLock {
            guard nextIndex < sockets.count else { throw ProviderError.unavailable }
            defer { nextIndex += 1 }; return sockets[nextIndex]
        }
    }
}
private final class LiveFixtureState: @unchecked Sendable {
    private let lock = NSLock()
    private var saved: [MeetingTurn] = []
    private var drafts: [LiveMeetingDraft] = []
    private var reject = false
    var turns: [MeetingTurn] { lock.withLock { saved } }
    var draftText: String { lock.withLock { drafts.last?.text ?? "" } }
    var allDrafts: [LiveMeetingDraft] { lock.withLock { drafts } }
    func failSaves() { lock.withLock { reject = true } }
    func persist(_ turns: [MeetingTurn]) throws { try lock.withLock { if reject { throw ProviderError.cacheWrite }; saved = turns } }
    func draft(_ value: LiveMeetingDraft) { lock.withLock { drafts.append(value) } }
}
private func liveFrame(_ source: Source = .mic, offset: Double, duration: Double = 0.4, signal: Bool = true, rms: Double? = nil) -> CapturedAudioFrame {
    let level = rms ?? (signal ? 0.2 : 0)
    let samples = [Float](repeating: Float(level), count: Int((duration * 16_000).rounded()))
    return samples.withUnsafeBytes { .init(source: source, offset: offset, pcmFloat32: Data($0), rms: level) }
}
/// Steady 16 kHz signal through a capture writer in `chunk`-frame buffers, with sub-millisecond
/// host-clock jitter like real devices, and optionally one 0.2 s clock gap.
private func writerFrames(_ root: URL, seconds: Double, chunk: Int, gapAt: Double? = nil) throws -> ([AudioSpan], [CapturedAudioFrame]) {
    let writer = PCMTrackWriter(directory: root, source: .mic, epoch: 1_000)
    var frames: [CapturedAudioFrame] = []
    writer.onAudioFrame = { frames.append($0) }
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk))!
    buffer.frameLength = AVAudioFrameCount(chunk); buffer.floatChannelData![0].initialize(repeating: 0.2, count: chunk)
    var position = 0, n = 0
    while Double(position) / 16_000 < seconds {
        let time = Double(position) / 16_000 + (gapAt.map { Double(position) / 16_000 >= $0 ? 0.2 : 0 } ?? 0)
        try writer.append(buffer, pts: 1_000 + time + 0.0008 * sin(Double(n) * 1.7))
        position += chunk; n += 1
    }
    return (writer.stop(), frames)
}
/// Offers frames no faster than the engine uploads them, so the bounded live queue never overflows.
private func feedPaced(_ controller: LiveMeetingController, socket: LiveFixtureSocket, _ frames: [CapturedAudioFrame]) async throws {
    let base = socket.appends
    for (i, frame) in frames.enumerated() {
        controller.offer(frame)
        try await liveUntil("paced frame uploaded") { socket.appends >= base + i }
    }
}
private func liveController(_ socket: LiveFixtureSocket, state: LiveFixtureState, continuous: Bool = false) -> LiveMeetingController {
    .init(realtimeURL: URL(string: "wss://live-fixture.invalid/v1/realtime?intent=transcription")!,
        config: .init(baseURL: URL(string: "https://fixture.invalid/v1")!, authValue: "Bearer local-fixture"), sources: [.mic],
        onPersist: { try state.persist($0) }, onDraft: { state.draft($0) }, socketFactory: { _ in socket },
        finishTimeout: 0.1, continuousDictation: continuous)
}
private final class RecoveryFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0, inFlight = 0, overlap = false, shown: [CaptureHealth] = []
    private var buffersAt = Int.max
    var recovery: SystemAudioRecovery!
    var attempts: Int { lock.withLock { count } }
    var overlapped: Bool { lock.withLock { overlap } }
    var health: [CaptureHealth] { lock.withLock { shown } }
    init(interval: TimeInterval, attemptSeconds: Double = 0) {
        recovery = SystemAudioRecovery(interval: interval) { [unowned self] in
            let number = self.lock.withLock { () -> Int in count += 1; inFlight += 1; overlap = overlap || inFlight > 1; return count }
            // Each restart reports Starting, as SystemAudioCapture.start does.
            self.report(.init(source: .system, state: .starting))
            if attemptSeconds > 0 { try? await Task.sleep(nanoseconds: UInt64(attemptSeconds * 1_000_000_000)) }
            if number >= self.lock.withLock({ buffersAt }) { self.report(.init(source: .system, state: .active)) }
            self.lock.withLock { inFlight -= 1 }
        }
    }
    func buffersArrive(fromAttempt number: Int) { lock.withLock { buffersAt = number } }
    func report(_ health: CaptureHealth) { if let shown = recovery.filter(health) { lock.withLock { self.shown.append(shown) } } }
    func down(_ state: CaptureHealthState = .interrupted) {
        report(.init(source: .system, state: state, message: "Mac audio stopped. Your microphone is still recording.")); recovery.begin()
    }
}
/// One two-second turn (the pause floor): 0.4 s of speech, then quiet until the pause ends it.
private func feedTurn(_ controller: LiveMeetingController, socket: LiveFixtureSocket, source: Source = .mic, start: Double) async throws {
    let appends = socket.appends
    controller.offer(liveFrame(source, offset: start))
    try await liveUntil("first live frame") { socket.appends > appends }
    for i in 1..<5 {
        controller.offer(liveFrame(source, offset: start + Double(i) * 0.4, signal: false))
        try await liveUntil("quiet live frame") { socket.appends > appends + i }
    }
}
private func controller(_ socket: LiveFixtureSocket, state: LiveFixtureState) -> LiveMeetingController {
    .init(realtimeURL: URL(string: "wss://live-fixture.invalid/v1/realtime?intent=transcription")!,
        config: .init(baseURL: URL(string: "https://fixture.invalid/v1")!, authValue: "Bearer local-fixture"), sources: [.mic],
        onPersist: { try state.persist($0) }, onDraft: { state.draft($0) }, socketFactory: { _ in socket })
}

private final class LiveRecoveryProtocol: URLProtocol {
    static let lock = NSLock()
    private static var seen: [URLRequest] = []
    private static var bodies: [Data] = []
    private static var responses: [String] = []
    static var requests: [URLRequest] { lock.withLock { seen } }
    static var requestBodies: [Data] { lock.withLock { bodies } }
    static func reset(_ text: [String] = []) { lock.withLock { seen = []; bodies = []; responses = text } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 8_192)
            while stream.hasBytesAvailable { let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; body.append(contentsOf: bytes.prefix(count)) }
        }
        let text = Self.lock.withLock { () -> String in
            Self.seen.append(request); Self.bodies.append(body)
            return Self.responses.isEmpty ? "Recovered fixture words." : Self.responses.removeFirst()
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: ["text": text]))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

public func runLiveMeetingSelftests() async -> Bool {
    let cases: [(String, () async throws -> Void)] = [
        ("retained dictation replays adjacent storage files as one continuous item", {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
            buffer.frameLength = 4_800
            for i in 0..<4_800 { buffer.floatChannelData![0][i] = 0.2 }
            var spans: [AudioSpan] = []
            for i in 0..<2 {
                let url = root.appendingPathComponent("part-\(i).wav")
                do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
                spans.append(.init(url: url, offset: Double(i) * 0.3, duration: 0.3))
            }
            let socket = LiveFixtureSocket(completeAtStop: true)
            let result = try await transcribeContinuousDictation(tracks: [.init(source: .mic, spans: spans)],
                config: .init(baseURL: URL(string: "https://fixture.invalid/v1")!, authValue: "Bearer local-fixture"),
                socketFactory: { request in
                    guard request.url?.absoluteString == "wss://fixture.invalid/v1/realtime?intent=transcription" else { throw ProviderError.configuration }
                    return socket
                })
            try liveCheck(result.complete && result.text == "Exact replayed words" && socket.commits == 1,
                          "retry uses live model once across file rotation, with no editor or file-ASR request")
            let uploaded = socket.requests.filter { $0["type"] as? String == "input_audio_buffer.append" }
                .compactMap { ($0["audio"] as? String).flatMap { Data(base64Encoded: $0) } }.reduce(0) { $0 + $1.count }
            try liveCheck(abs(uploaded - 28_800) <= 4, "all 0.6 seconds are replayed without overlap or lost samples")
            let cancelled = LiveFixtureSocket()
            let task = Task { try await transcribeContinuousDictation(tracks: [.init(source: .mic, spans: spans)],
                config: .init(baseURL: URL(string: "https://fixture.invalid/v1")!, authValue: "Bearer local-fixture"),
                socketFactory: { _ in cancelled }) }
            try await liveUntil("retry starts uploading") { cancelled.appends > 0 }
            task.cancel()
            do { _ = try await task.value; throw LiveCheckFailure(name: "cancelled retry returned output") }
            catch is CancellationError {}
            try liveCheck(cancelled.isClosed && spans.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) },
                          "cancelled replay closes transport and preserves every saved audio part")
        }),
        ("continuous startup preserves the prefix through a delayed configuration", {
            let socket = LiveFixtureSocket(blockConfiguration: true), state = LiveFixtureState()
            let live = LiveMeetingController(realtimeURL: URL(string: "wss://fixture.invalid/v1/realtime")!,
                config: .init(baseURL: URL(string: "https://fixture.invalid/v1")!, authValue: "Bearer local-fixture"),
                sources: [.mic], onPersist: { try state.persist($0) }, onDraft: { state.draft($0) }, socketFactory: { request in
                    try liveCheck(request.timeoutInterval == 330, "continuous transport supports the full recording duration")
                    return socket
                },
                continuousDictation: true)
            await live.start()
            try await liveUntil("slow configuration started") { !socket.requests.isEmpty }
            for i in 0..<18 {
                live.offer(liveFrame(offset: Double(i) * 0.4))
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            try liveCheck(!socket.isClosed && socket.commits == 0, "startup preserves more than two seconds without reconnecting")
            socket.push(["type": "session.updated", "session": ["type": "transcription"]])
            // This later server event is handled only after configuration has
            // drained the complete buffered prefix, regardless of wire packet sizes.
            socket.push(["type": "conversation.item.input_audio_transcription.delta", "item_id": "prefix", "delta": "Prefix drained"])
            try await liveUntil("startup prefix drained") { state.draftText == "Prefix drained" }
            let turns = await live.cancel()
            try liveCheck(turns.count == 1 && turns[0].start == 0 && abs(turns[0].end - 7.2) < 0.001,
                          "buffered prefix survives cancellation: \(turns.map { "\($0.start)-\($0.end):\($0.state.rawValue)" })")
        }),
        ("continuous upload jitter preserves queued speech without restarting", {
            let socket = LiveFixtureSocket(blockAudio: true), state = LiveFixtureState()
            let live = LiveMeetingController(realtimeURL: URL(string: "wss://fixture.invalid/v1/realtime")!,
                config: .init(baseURL: URL(string: "https://fixture.invalid/v1")!, authValue: "Bearer local-fixture"),
                sources: [.mic], onPersist: { try state.persist($0) }, onDraft: { state.draft($0) },
                socketFactory: { _ in socket }, continuousDictation: true)
            await live.start(); live.offer(liveFrame(offset: 0))
            try await liveUntil("stalled upload starts") { socket.appends > 0 }
            for i in 1..<19 { live.offer(liveFrame(offset: Double(i) * 0.4)) }
            socket.releaseAudio()
            socket.push(["type": "conversation.item.input_audio_transcription.delta", "item_id": "stream", "delta": "Queue drained"])
            try await liveUntil("bounded upload queue drained") { state.draftText == "Queue drained" }
            try liveCheck(!socket.isClosed && socket.commits == 0, "brief upload stalls do not restart or cut the live stream")
            let turns = await live.cancel()
            try liveCheck(turns.count == 1 && turns[0].start == 0 && abs(turns[0].end - 7.6) < 0.001,
                          "queued speech retains complete capture coverage")
        }),
        ("continuous dictation streams beyond old cuts and finalizes once at stop", {
            let socket = LiveFixtureSocket(), state = LiveFixtureState()
            let live = LiveMeetingController(realtimeURL: URL(string: "wss://fixture.invalid/v1/realtime")!,
                config: .init(baseURL: URL(string: "https://fixture.invalid/v1")!, authValue: "Bearer local-fixture"),
                sources: [.mic], onPersist: { try state.persist($0) }, onDraft: { state.draft($0) },
                socketFactory: { _ in socket }, continuousDictation: true)
            await live.start()
            for i in 0..<75 {
                let before = socket.appends
                live.offer(liveFrame(offset: Double(i) * 0.4, signal: i % 8 < 5))
                try await liveUntil("continuous frame uploaded") { socket.appends > before }
            }
            try liveCheck(socket.commits == 0 && state.turns.isEmpty, "no timed cuts, pause cuts or overlap before stop")
            socket.push(["type": "conversation.item.input_audio_transcription.delta", "item_id": "stream", "delta": "Live "])
            try await liveUntil("live draft before any commit") { state.draftText == "Live " }
            // More than the old early-event cap: a long stream must aggregate
            // drafts instead of retaining every pre-commit delta event.
            for _ in 0..<200 {
                socket.push(["type": "conversation.item.input_audio_transcription.delta", "item_id": "stream", "delta": "word "])
            }
            let finish = Task { await live.finish() }
            try await liveUntil("single continuous stop commit") { socket.commits == 1 }
            socket.push(["type": "input_audio_buffer.committed", "item_id": "stream", "previous_item_id": NSNull()])
            socket.push(["type": "conversation.item.input_audio_transcription.completed", "item_id": "stream", "transcript": "Live final words."])
            let turns = await finish.value
            try liveCheck(turns.count == 1 && turns[0].state == .confirmed && turns[0].start == 0
                && abs(turns[0].end - 30) < 0.001 && turns[0].text == "Live final words." && socket.commits == 1,
                "one final item covers exact full capture and uses completed text, without replayed drafts")
        }),
        ("continuous dictation supports all five minutes without an append-ID cutoff", {
            let socket = LiveFixtureSocket(), state = LiveFixtureState()
            let live = LiveMeetingController(realtimeURL: URL(string: "wss://fixture.invalid/v1/realtime")!,
                config: .init(baseURL: URL(string: "https://fixture.invalid/v1")!, authValue: "Bearer local-fixture"),
                sources: [.mic], onPersist: { try state.persist($0) }, socketFactory: { _ in socket },
                continuousDictation: true)
            await live.start()
            for i in 0..<6_000 {
                live.offer(liveFrame(offset: Double(i) * 0.05, duration: 0.05))
                if i % 10 == 9 { try await liveUntil("five-minute frame batch uploaded") { socket.appends >= i + 1 } }
            }
            try liveCheck(socket.commits == 0 && !socket.isClosed, "all 6000 frames stream without a forced cut or artificial event limit")
            let finish = Task { await live.finish() }
            try await liveUntil("five-minute final commit") { socket.commits == 1 }
            socket.push(["type": "input_audio_buffer.committed", "item_id": "full", "previous_item_id": NSNull()])
            socket.push(["type": "conversation.item.input_audio_transcription.completed", "item_id": "full", "transcript": "Full five-minute dictation."])
            let turns = await finish.value
            try liveCheck(turns.count == 1 && turns[0].state == .confirmed && turns[0].start == 0
                          && abs(turns[0].end - 300) < 0.001, "one completed item seals the full five-minute capture")
        }),
        ("live dictation keeps plain ordered words and its experiment metadata", {
            var record = SessionRecord(kind: .dictation, title: "Dictation")
            record.liveDictationVersion = 1; record.dictationPerformance = .init(mode: .live)
            try record.applyMeetingTurns([
                .init(idx: 1, source: .mic, start: 1, end: 2, state: .confirmed, text: "second sentence."),
                .init(idx: 0, source: .mic, start: 0, end: 1, state: .confirmed, text: "First sentence,")])
            try liveCheck(record.transcript == "First sentence, second sentence." && record.rawTranscript == record.transcript,
                          "dictation must never acquire source labels or timestamps")
            let restored = try JSONDecoder().decode(SessionRecord.self, from: JSONEncoder().encode(record))
            try liveCheck(restored.liveDictationVersion == 1 && restored.liveMeetingVersion == nil &&
                          restored.dictationPerformance?.mode == .live && restored.meetingTurns == record.meetingTurns,
                          "experiment mode and durable coverage must survive restart independently of the setting")
            try liveCheck(restored.fixGrammar == nil, "old recordings decode without retired local-trial metadata")
            record.liveDictationVersion = 4; record.fixGrammar = false
            let continuous = try JSONDecoder().decode(SessionRecord.self, from: JSONEncoder().encode(record))
            try liveCheck(continuous.usesContinuousDictation && continuous.fixGrammar == false,
                          "continuous mode and no-cleanup choice survive restart together")
        }),
        ("short dictation finalization deadline preserves unconfirmed audio for recovery", {
            let socket = LiveFixtureSocket(), state = LiveFixtureState()
            let live = LiveMeetingController(realtimeURL: URL(string: "wss://fixture.invalid/v1/realtime?intent=transcription")!,
                config: .init(baseURL: URL(string: "https://fixture.invalid/v1")!, authValue: "Bearer local-fixture"),
                sources: [.mic], onPersist: { try state.persist($0) }, socketFactory: { _ in socket }, finishTimeout: 0.1)
            await live.start(); try await feedTurn(live, socket: socket, start: 0)
            try await liveUntil("dictation pending commit") { socket.commits == 1 }
            let started = ProcessInfo.processInfo.systemUptime
            let turns = await live.finish()
            try liveCheck(ProcessInfo.processInfo.systemUptime - started < 2 && socket.isClosed &&
                          turns.first?.state == .needsRecovery && abs((turns.first?.end ?? 0) - 2) < 0.0001,
                          "a delayed completion cannot stall dictation or discard its audio interval")
        }),
        ("canonical PCM and live configuration", {
            let delta = try LiveTranscriptionEvent.parse(JSONSerialization.data(withJSONObject: [
                "type": "conversation.item.input_audio_transcription.delta", "item_id": "fixture", "delta": "new words", "transcript": "full old and new words"]))
            try liveCheck(delta.text == "new words", "delta events use incremental text rather than an optional cumulative transcript")
            let configuration = try LiveProtocol.configuration(languages: ["es", "pt"], keywords: ["Tomas"], eventID: "fixture-config")
            let json = try JSONSerialization.jsonObject(with: configuration) as! [String: Any]
            let input = ((json["session"] as! [String: Any])["audio"] as! [String: Any])["input"] as! [String: Any]
            let transcription = input["transcription"] as! [String: Any]
            try liveCheck(transcription["model"] as? String == "gpt-live-transcribe" && transcription["prompt"] == nil && input["turn_detection"] is NSNull, "fixed transcription-only config")
            let continuousData = try LiveProtocol.configuration(languages: [], keywords: [], eventID: "continuous", minimalDelay: true)
            let continuousJSON = try JSONSerialization.jsonObject(with: continuousData) as! [String: Any]
            let continuousInput = ((continuousJSON["session"] as! [String: Any])["audio"] as! [String: Any])["input"] as! [String: Any]
            let continuousASR = continuousInput["transcription"] as! [String: Any]
            try liveCheck(continuousASR["model"] as? String == "gpt-live-transcribe" && continuousASR["delay"] as? String == "minimal"
                          && continuousInput["turn_detection"] is NSNull, "continuous dictation requests the lowest-delay live stream")

        }),
        ("safe realtime account and configuration aliases", {
            for (code, expected) in [("account_deactivated", ServiceFailureKind.accessDenied), ("billing_hard_limit_reached", .billingLimit), ("invalid_config", .configuration)] {
                let data = try JSONSerialization.data(withJSONObject: ["type": "error", "error": ["code": code]])
                let parsed = try LiveTranscriptionEvent.parse(data)
                try liveCheck(parsed.failure == expected, "account failures do not become network reconnect loops")
            }
            for (type, expected) in [("authentication_error", ServiceFailureKind.invalidCredential), ("permission_error", .accessDenied), ("invalid_request_error", .configuration)] {
                let data = try JSONSerialization.data(withJSONObject: ["type": "error", "error": ["code": "unknown", "type": type]])
                let parsed = try LiveTranscriptionEvent.parse(data)
                try liveCheck(parsed.failure == expected, "safe error types classify unknown codes")
            }
            try liveCheck(LiveMeetingDraft(source: .mic, itemID: "same", text: "").id != LiveMeetingDraft(source: .system, itemID: "same", text: "").id,
                          "source-local item IDs never collide in view")
        }),
        ("sealed empty coverage immutable IDs and summary revision", {
            var record = SessionRecord(kind: .meeting, title: "Fixture")
            record.liveMeetingVersion = 1
            record.tracks = [.init(source: .mic, spans: [.init(url: URL(fileURLWithPath: "/fixture.wav"), offset: 0, duration: 601)])]
            let empty = MeetingTurn(idx: 0, source: .mic, start: 0, end: 1, state: .confirmed)
            try record.applyMeetingTurns([empty])
            record.summary = "Fixture summary"; record.summaryTranscriptRevision = record.transcriptRevision
            let planned = planMeetingRecovery(tracks: record.tracks, turns: record.meetingTurns)
            try liveCheck(planned.count == 3 && planned[1].end - planned[1].start == 300 && planned[2].idx == 2,
                          "never-submitted backlog coalesces before stable IDs")
            var next = planned; next[1].state = .confirmed; next[1].text = "Later fixture passage"
            try record.applyMeetingTurns(next)
            try liveCheck(record.summaryIsStale && record.segments[0].turnID == "turn-1" && record.segments[0].timing == .audioInterval,
                          "whole transcript revision detects summary staleness")
            var invalid = next; invalid[0].text = "Changed words"
            do { try record.applyMeetingTurns(invalid); throw LiveCheckFailure(name: "confirmed empty cannot be overwritten") }
            catch let failure as LiveCheckFailure { throw failure } catch {}
            let data = try JSONEncoder().encode(record)
            let restored = try JSONDecoder().decode(SessionRecord.self, from: data)
            try liveCheck(restored.meetingTurns == next && restored.summaryIsStale, "live ledger survives coding")
        }),
        ("early deltas reordered completion and permanent text", {
            let socket = LiveFixtureSocket(), state = LiveFixtureState(), live = controller(socket, state: state)
            await live.start()
            try await feedTurn(live, socket: socket, start: 0)
            try await liveUntil("first committed interval") { socket.commits == 1 }
            socket.push(["type": "conversation.item.input_audio_transcription.delta", "item_id": "item-A", "delta": "Draft"])
            try await liveUntil("draft before ACK") { state.draftText == "Draft" }
            socket.push(["type": "input_audio_buffer.committed", "item_id": "item-A", "previous_item_id": NSNull()])
            try await feedTurn(live, socket: socket, start: 2)
            try await liveUntil("second committed interval") { socket.commits == 2 }
            socket.push(["type": "input_audio_buffer.committed", "item_id": "item-B", "previous_item_id": "item-A"])
            socket.push(["type": "conversation.item.input_audio_transcription.completed", "item_id": "item-B", "transcript": "Later"])
            socket.push(["type": "conversation.item.input_audio_transcription.completed", "item_id": "item-A", "transcript": "Earlier"])
            try await liveUntil("reordered completions durable") { state.turns.filter { $0.state == .confirmed }.count == 2 }
            socket.push(["type": "conversation.item.input_audio_transcription.completed", "item_id": "item-A", "transcript": "Changed"])
            let turns = await live.finish()
            try liveCheck(turns.map(\.text) == ["Earlier", "Later"] && turns.map(\.idx) == [0, 1], "no rewrite or arrival-order ID shift")
            let ids = socket.requests.compactMap { $0["event_id"] as? String }
            try liveCheck(ids.count == Set(ids).count && ids.count == socket.requests.count, "every outgoing event has unique ID")
            var frames = 0, counts: [Int] = []
            for request in socket.requests {
                if let audio = request["audio"] as? String { frames += Data(base64Encoded: audio)!.count / 2 }
                if request["type"] as? String == "input_audio_buffer.commit" { counts.append(frames); frames = 0 }
            }
            try liveCheck(counts.count == 2 && counts.allSatisfy({ abs($0 - 48_000) <= 2 }),
                          "each committed interval contains its own complete converter tail " + counts.map(String.init).joined(separator: ","))
        }),
        ("slow system configuration cannot stall healthy microphone", {
            let pair = LiveSocketPair(), state = LiveFixtureState()
            let live = LiveMeetingController(realtimeURL: URL(string: "wss://fixture.invalid/v1/realtime?intent=transcription")!,
                config: .init(baseURL: URL(string: "https://fixture.invalid/v1")!, authValue: "Bearer local-fixture"),
                sources: [.mic, .system], onPersist: { try state.persist($0) }, socketFactory: { _ in pair.next() })
            await live.start(); try await feedTurn(live, socket: pair.mic, start: 4)
            try await liveUntil("mic commits while system send blocked") { pair.mic.commits == 1 }
            pair.mic.push(["type": "input_audio_buffer.committed", "item_id": "mic-A", "previous_item_id": NSNull()])
            pair.mic.push(["type": "conversation.item.input_audio_transcription.completed", "item_id": "mic-A", "transcript": "Mic words"])
            try await liveUntil("mic confirmation independent") { state.turns.first?.state == .confirmed }
            try liveCheck(!pair.system.isClosed && pair.system.appends == 0, "system still waiting for configuration while mic confirms")
            let result = await live.finish()
            try liveCheck(result.count == 1 && result[0].start == 4 && result[0].text == "Mic words", "shared epoch preserved with independent startup")
        }),
        ("rejected commit fails generation closed", {
            let socket = LiveFixtureSocket(), state = LiveFixtureState(), live = controller(socket, state: state)
            await live.start(); try await feedTurn(live, socket: socket, start: 0)
            try await liveUntil("pending commit") { socket.commits == 1 }
            socket.push(["type": "error", "error": ["code": "rate_limit_exceeded", "type": "invalid_request_error", "event_id": "fixture-rejected"]])
            socket.push(["type": "input_audio_buffer.committed", "item_id": "wrong-ACK", "previous_item_id": NSNull()])
            socket.push(["type": "conversation.item.input_audio_transcription.completed", "item_id": "wrong-ACK", "transcript": "Wrong range"])
            try await liveUntil("generation closed") { socket.isClosed }
            let turns = await live.finish()
            try liveCheck(turns.count == 1 && turns[0].state == .needsRecovery && turns[0].text.isEmpty && turns[0].failureKind == .rateLimited,
                          "no ACK can shift past a rejected commit")
        }),
        ("short tail and bounded queue retain raw recovery", {
            let socket = LiveFixtureSocket(), state = LiveFixtureState(), live = controller(socket, state: state)
            await live.start(); live.offer(liveFrame(offset: 2, duration: 0.02))
            try await liveUntil("short audio uploaded") { socket.appends > 0 }
            let turns = await live.finish()
            try liveCheck(socket.commits == 0 && turns.count == 1 && turns[0].state == .needsRecovery,
                          "very short tail is not forced through server commit")
            let overflowSocket = LiveFixtureSocket(), overflowState = LiveFixtureState()
            let overflow = controller(overflowSocket, state: overflowState)
            await overflow.start(); overflow.offer(liveFrame(offset: 0, duration: 3))
            _ = await overflow.cancel()
            let tracks = [SessionAudioTrack(source: .mic, spans: [.init(url: URL(fileURLWithPath: "/fixture.wav"), offset: 0, duration: 3)])]
            let planned = planMeetingRecovery(tracks: tracks, turns: overflowState.turns)
            try liveCheck(overflowSocket.appends == 0 && planned.count == 1 && planned[0].end == 3,
                          "queue overflow keeps full captured interval recoverable")
        }),
        ("failed confirmation save cannot become permanent", {
            let socket = LiveFixtureSocket(), state = LiveFixtureState(), live = controller(socket, state: state)
            await live.start(); try await feedTurn(live, socket: socket, start: 0)
            try await liveUntil("pending saved") { socket.commits == 1 }
            socket.push(["type": "input_audio_buffer.committed", "item_id": "item-A", "previous_item_id": NSNull()])
            state.failSaves()
            socket.push(["type": "conversation.item.input_audio_transcription.completed", "item_id": "item-A", "transcript": "Unsaved words"])
            try await liveUntil("failed-save transport closed") { socket.isClosed }
            let result = await live.finish()
            try liveCheck(!result.contains { $0.state == .confirmed } && state.turns[0].text.isEmpty,
                          "durable-save failure retains pending audio without accepted words")
        }),
        ("global stop deadline interrupts blocked audio and never reconnects", {
            let socket = LiveFixtureSocket(blockAudio: true), sequence = LiveSocketSequence([socket]), state = LiveFixtureState()
            let live = LiveMeetingController(realtimeURL: URL(string: "wss://fixture.invalid/v1/realtime?intent=transcription")!,
                config: .init(baseURL: URL(string: "https://fixture.invalid/v1")!, authValue: "Bearer local-fixture"),
                sources: [.mic], onPersist: { try state.persist($0) }, socketFactory: { _ in try sequence.next() })
            await live.start(); live.offer(liveFrame(offset: 0))
            try await liveUntil("audio send blocked") { socket.appends == 1 }
            live.offer(liveFrame(offset: 0.4))
            let started = Date(); let turns = await live.finish()
            try liveCheck(Date().timeIntervalSince(started) < 12 && socket.isClosed && sequence.calls == 1,
                          "one deadline closes in-flight audio and prohibits new generation")
            try liveCheck(turns.count == 1 && turns[0].state == .needsRecovery && turns[0].text.isEmpty,
                          "blocked payload remains recovery rather than confirmed coverage")
            _ = await live.cancel()
        }),
        ("quit cancellation overlaps finish without waiting the global deadline", {
            let socket = LiveFixtureSocket(blockAudio: true), state = LiveFixtureState(), live = controller(socket, state: state)
            await live.start(); live.offer(liveFrame(offset: 0))
            try await liveUntil("cancellation audio blocked") { socket.appends == 1 }
            let finish = Task { await live.finish() }
            await Task.yield()
            let started = Date(), cancelled = await live.cancel(), finished = await finish.value
            try liveCheck(Date().timeIntervalSince(started) < 1 && cancelled == finished && socket.isClosed,
                          "overlapping finish and cancel share worker and stop timer safely")
        }),
        ("interrupted live record refreshes growing captured manifest and refuses incomplete cleanup", {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try SessionStore(root: root), record = SessionRecord(kind: .meeting, title: "Crash fixture")
            let directory = store.directory(for: record.id)
            var live = record; live.liveMeetingVersion = 1; live.status = .recording
            try store.save(live)
            let audio = directory.appendingPathComponent("mic_part_00000.wav")
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_000)!
            buffer.frameLength = 32_000; buffer.floatChannelData![0].initialize(repeating: 0.2, count: 32_000)
            do { let file = try AVAudioFile(forWriting: audio, settings: format.settings); try file.write(from: buffer) }
            live.tracks = [.init(source: .mic, spans: [.init(url: audio, offset: 4, duration: 1)])]
            try live.applyMeetingTurns([.init(idx: 0, source: .mic, start: 4, end: 5, state: .confirmed, text: "Permanent before crash")])
            try store.save(live)
            // Even stale manifest duration must be reconciled against readable canonical bytes.
            try JSONEncoder().encode(live.tracks[0]).write(to: directory.appendingPathComponent("mic-capture.json"))
            var restored = try store.load()[0]
            try liveCheck(restored.tracks[0].spans[0].duration == 2 && restored.meetingTurns == live.meetingTurns && restored.canRecover,
                          "already populated raw spans grow without changing confirmed history")
            restored.status = .complete; restored.captureIncomplete = false
            try store.cleanAudio(for: restored)
            try liveCheck(FileManager.default.fileExists(atPath: audio.path), "status alone never permits deleting missing coverage")
        }),
        ("partial append failure ignores stale generation while reconnect preserves confirmed IDs", {
            let first = LiveFixtureSocket(failAudioAfter: 100), second = LiveFixtureSocket()
            let sequence = LiveSocketSequence([first, second]), state = LiveFixtureState()
            let live = LiveMeetingController(realtimeURL: URL(string: "wss://fixture.invalid/v1/realtime?intent=transcription")!,
                config: .init(baseURL: URL(string: "https://fixture.invalid/v1")!, authValue: "Bearer local-fixture"),
                sources: [.mic], onPersist: { try state.persist($0) }, socketFactory: { _ in try sequence.next() })
            await live.start(); try await feedTurn(live, socket: first, start: 0)
            try await liveUntil("first generation commit") { first.commits == 1 }
            first.push(["type": "input_audio_buffer.committed", "item_id": "first", "previous_item_id": NSNull()])
            first.push(["type": "conversation.item.input_audio_transcription.completed", "item_id": "first", "transcript": "Permanent"])
            try await liveUntil("first generation confirmed") { state.turns.first?.state == .confirmed }
            first.setAudioFailure(after: first.appends + 1)
            live.offer(liveFrame(offset: 2))
            try await liveUntil("partial append fails") { first.isClosed }
            first.push(["type": "input_audio_buffer.committed", "item_id": "stale", "previous_item_id": "first"])
            first.push(["type": "conversation.item.input_audio_transcription.completed", "item_id": "stale", "transcript": "Must not survive"])
            try await Task.sleep(nanoseconds: 2_100_000_000)
            try await feedTurn(live, socket: second, start: 3)
            try await liveUntil("reconnected commit") { second.commits == 1 }
            second.push(["type": "input_audio_buffer.committed", "item_id": "second", "previous_item_id": NSNull()])
            second.push(["type": "conversation.item.input_audio_transcription.completed", "item_id": "second", "transcript": "New passage"])
            try await liveUntil("reconnected durable confirmation") { state.turns.filter { $0.state == .confirmed }.count == 2 }
            let turns = await live.finish()
            try liveCheck(turns.count == 3 && turns[0].idx == 0 && turns[0].text == "Permanent" &&
                          turns[1].state == .needsRecovery && turns[2].idx == 2 && turns[2].text == "New passage",
                          "confirmed words stable and partially appended range remains missing")
        }),
        ("advertised expiry rotates without changing old confirmed or missing coverage", {
            let first = LiveFixtureSocket(), second = LiveFixtureSocket(), sequence = LiveSocketSequence([first, second]), state = LiveFixtureState()
            let live = LiveMeetingController(realtimeURL: URL(string: "wss://fixture.invalid/v1/realtime?intent=transcription")!,
                config: .init(baseURL: URL(string: "https://fixture.invalid/v1")!, authValue: "Bearer local-fixture"),
                sources: [.mic], onPersist: { try state.persist($0) }, socketFactory: { _ in try sequence.next() })
            await live.start(); try await feedTurn(live, socket: first, start: 0)
            try await liveUntil("expiry fixture commit") { first.commits == 1 }
            first.push(["type": "input_audio_buffer.committed", "item_id": "before-expiry", "previous_item_id": NSNull()])
            first.push(["type": "conversation.item.input_audio_transcription.completed", "item_id": "before-expiry", "transcript": "Before expiry"])
            try await liveUntil("expiry fixture confirmation") { state.turns.first?.state == .confirmed }
            let committedAppends = first.appends
            live.offer(liveFrame(offset: 2)); try await liveUntil("uncommitted audio before expiry") { first.appends > committedAppends }
            first.push(["type": "session.created", "session": ["type": "transcription", "expires_at": Date().timeIntervalSince1970 + 10]])
            // Queue order ensures the advertised deadline is processed before the next real frame.
            try await Task.sleep(nanoseconds: 10_000_000)
            live.offer(liveFrame(offset: 2.4)); try await liveUntil("expiry rotation") { sequence.calls == 2 && first.isClosed }
            let result = await live.cancel()
            try liveCheck(result[0].text == "Before expiry" && result[0].state == .confirmed &&
                          result.contains { $0.start == 2 && $0.end == 2.4 && $0.state == .needsRecovery },
                          "expiry preserves confirmed identity and old generation open range")
        }),
        ("turn runs across a 45 s capture rotation", {
            for chunk in [1_600, 1_024] { // rotation at a buffer's end, and inside one
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: root) }
                let (spans, frames) = try writerFrames(root, seconds: 47, chunk: chunk)
                try liveCheck(spans.count == 2 && spans[0].duration == 45 && abs(spans[1].offset - (spans[0].offset + spans[0].duration)) < 1e-9,
                              "a full part continues at the previous offset plus its duration (\(chunk))")
                try liveCheck(zip(frames, frames.dropFirst()).allSatisfy { abs($1.offset - ($0.offset + $0.duration)) <= 1 / 8_000 },
                              "frame offsets stay on the span timeline across the rotation (\(chunk))")
                try validateCapturedMeetingInterval(track: .init(source: .mic, spans: spans), start: 44, end: 46)
                let socket = LiveFixtureSocket(), state = LiveFixtureState(), live = liveController(socket, state: state)
                await live.start()
                try await feedPaced(live, socket: socket, frames.filter { $0.offset >= 43.6 && $0.offset < 46.4 })
                let turns = await live.finish()
                try liveCheck(socket.commits == 1 && turns.count == 1 && turns[0].start < 45 && turns[0].end > 45 && turns[0].endReason == .stopped,
                              "the live turn is not cut at the rotation (\(chunk))")
                try validateCapturedMeetingInterval(track: .init(source: .mic, spans: spans), start: turns[0].start, end: turns[0].end)
            }
        }),
        ("dictation longer than 45 s is one turn", {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let (_, frames) = try writerFrames(root, seconds: 47, chunk: 1_024)
            let socket = LiveFixtureSocket(), state = LiveFixtureState(), live = liveController(socket, state: state, continuous: true)
            await live.start(); try await feedPaced(live, socket: socket, frames)
            let turns = await live.finish()
            try liveCheck(socket.commits == 1 && turns.count == 1 && turns[0].start == 0 && abs(turns[0].end - 47.0) < 0.07,
                          "one commit covers the whole dictation")
        }),
        ("a 0.12 s clock gap still ends the turn", {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let (spans, frames) = try writerFrames(root, seconds: 2.5, chunk: 1_600, gapAt: 1)
            try liveCheck(spans.count == 2 && abs(spans[1].offset - 1.2) < 0.001, "a gap starts a part on the host clock")
            let socket = LiveFixtureSocket(), state = LiveFixtureState(), live = liveController(socket, state: state)
            await live.start(); try await feedPaced(live, socket: socket, frames)
            let turns = await live.finish()
            try liveCheck(turns.count == 2 && turns[0].endReason == .discontinuity && abs(turns[0].end - 1) < 0.001 && abs(turns[1].start - 1.2) < 0.001,
                          "the gap ends the turn at the last real sample")
        }),
        ("a pause ends a turn only once it is 2 s long", {
            let socket = LiveFixtureSocket(), state = LiveFixtureState(), live = liveController(socket, state: state)
            await live.start()
            // Room noise above the old 0.0001 threshold and below 0.004 counts as quiet.
            try await feedPaced(live, socket: socket, [liveFrame(offset: 0)] + (1..<4).map { liveFrame(offset: Double($0) * 0.4, rms: 0.003) })
            try await Task.sleep(nanoseconds: 50_000_000)
            try liveCheck(socket.commits == 0, "1.2 s of quiet does not end a 1.6 s turn")
            live.offer(liveFrame(offset: 1.6, rms: 0.003))
            try await liveUntil("pause commit at the floor") { socket.commits == 1 }
            try liveCheck(state.turns.first?.endReason == .pause && state.turns.first?.end == 2, "the pause ends the turn once it is 2 s")
            _ = await live.cancel()
        }),
        ("drafts carry their turn and announce it at the commit acknowledgement", {
            let socket = LiveFixtureSocket(), state = LiveFixtureState(), live = controller(socket, state: state)
            await live.start(); try await feedTurn(live, socket: socket, start: 0)
            try await liveUntil("first commit") { socket.commits == 1 }
            socket.push(["type": "conversation.item.input_audio_transcription.delta", "item_id": "item-A", "delta": "Hel"])
            socket.push(["type": "conversation.item.input_audio_transcription.delta", "item_id": "item-A", "delta": "lo"])
            socket.push(["type": "input_audio_buffer.committed", "item_id": "item-A", "previous_item_id": NSNull()])
            try await liveUntil("draft announces its turn") { state.allDrafts.contains { $0.turnIdx == 0 } }
            let drafts = state.allDrafts, first = drafts.firstIndex { $0.turnIdx == 0 }!
            try liveCheck(drafts[..<first].allSatisfy { $0.turnIdx == nil && $0.itemID == "item-A" } && drafts[first].text == "Hello",
                          "an unmapped draft has no turn; the ACK emits the accumulated text inside the throttle window")
            socket.push(["type": "conversation.item.input_audio_transcription.completed", "item_id": "item-A", "transcript": "Hello."])
            try await liveUntil("completion clears draft") { state.allDrafts.last?.text == "" }
            try liveCheck(state.allDrafts.last?.turnIdx == 0, "the clearing draft keeps its turn")
            try await feedTurn(live, socket: socket, start: 2)
            try await liveUntil("second commit") { socket.commits == 2 }
            socket.push(["type": "input_audio_buffer.committed", "item_id": "item-B", "previous_item_id": "item-A"])
            try await liveUntil("textless item announces its turn") { state.allDrafts.last?.itemID == "item-B" }
            try liveCheck(state.allDrafts.last?.turnIdx == 1 && state.allDrafts.last?.text == "", "an ACK before any delta still announces the turn")
            try await Task.sleep(nanoseconds: 120_000_000)
            socket.push(["type": "conversation.item.input_audio_transcription.delta", "item_id": "item-B", "delta": "Bee"])
            try await liveUntil("mapped delta") { state.allDrafts.last?.text == "Bee" }
            try liveCheck(state.allDrafts.last?.turnIdx == 1, "a mapped delta carries its turn")
            socket.push(["type": "error", "error": ["code": "server_error", "type": "server_error"]])
            try await liveUntil("invalidation clears draft") { socket.isClosed && state.allDrafts.last?.text == "" }
            try liveCheck(state.allDrafts.last?.turnIdx == 1, "the invalidation clearing draft keeps its turn")
            _ = await live.cancel()
        }),
        ("stopped Mac audio restarts until buffers arrive", {
            let fixture = RecoveryFixture(interval: 10)
            fixture.buffersArrive(fromAttempt: 1); fixture.down()
            try await liveUntil("restart at once") { fixture.attempts == 1 && !fixture.recovery.isDown }
            try liveCheck(fixture.health.map(\.state) == [.interrupted, .active], "Starting is hidden and buffers report it active")
            await fixture.recovery.stop()
        }),
        ("failed Mac audio start retries every interval and stays down", {
            let fixture = RecoveryFixture(interval: 0.03)
            fixture.down(.unavailable)
            try await liveUntil("repeated restarts") { fixture.attempts >= 3 }
            try liveCheck(fixture.health.map(\.state) == [.unavailable] && fixture.recovery.isDown, "failed attempts never show Starting")
            fixture.report(.init(source: .system, state: .silent, message: "No Mac audio has arrived yet."))
            try liveCheck(fixture.health.count == 1, "the first-buffer wait of an attempt is hidden")
            fixture.buffersArrive(fromAttempt: fixture.attempts + 1)
            try await liveUntil("recovered") { !fixture.recovery.isDown }
            let attempts = fixture.attempts
            try await Task.sleep(nanoseconds: 100_000_000)
            try liveCheck(fixture.attempts == attempts && fixture.health.last?.state == .active, "the loop ends at the first buffer")
            try liveCheck(fixture.recovery.begin(), "a later failure starts a new loop")
            await fixture.recovery.stop()
        }),
        ("one Mac audio failure starts one loop", {
            let fixture = RecoveryFixture(interval: 0.1, attemptSeconds: 0.02)
            fixture.down()
            try liveCheck(!fixture.recovery.begin() && !fixture.recovery.begin(), "further triggers while down do nothing")
            try await Task.sleep(nanoseconds: 50_000_000)
            try liveCheck(fixture.attempts == 1, "one attempt at once, not one per trigger")
            try await liveUntil("loop continues") { fixture.attempts >= 3 }
            try liveCheck(!fixture.overlapped, "attempts never overlap")
            await fixture.recovery.stop()
        }),
        ("stop cancels the Mac audio restart loop", {
            let fixture = RecoveryFixture(interval: 10)
            fixture.down()
            try await liveUntil("first attempt") { fixture.attempts == 1 }
            let started = Date()
            await fixture.recovery.stop()
            try liveCheck(Date().timeIntervalSince(started) < 1, "stop does not wait out the interval")
            try liveCheck(!fixture.recovery.begin() && !fixture.recovery.isDown, "nothing restarts after stop")
            let busy = RecoveryFixture(interval: 0.01, attemptSeconds: 0.1)
            busy.down()
            try await liveUntil("attempt in flight") { busy.attempts == 1 }
            await busy.recovery.stop()
            let after = busy.attempts
            try await Task.sleep(nanoseconds: 100_000_000)
            try liveCheck(after == 1 && busy.attempts == 1, "stop waits for an attempt in flight and starts no other")
        }),
        ("missing-only recovery cache and actual capture gaps", {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let audio = root.appendingPathComponent("raw.wav")
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_000)!
            buffer.frameLength = 32_000; buffer.floatChannelData![0].initialize(repeating: 0.2, count: 32_000)
            do { let file = try AVAudioFile(forWriting: audio, settings: format.settings); try file.write(from: buffer) }
            let track = SessionAudioTrack(source: .mic, spans: [.init(url: audio, offset: 4, duration: 2)])
            let original = MeetingTurn(idx: 0, source: .mic, start: 4, end: 5, state: .confirmed, text: "Permanent words")
            let state = LiveFixtureState(), configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [LiveRecoveryProtocol.self]
            let session = URLSession(configuration: configuration)
            LiveRecoveryProtocol.reset()
            let config = OpenAIConfig(baseURL: URL(string: "https://fixture.invalid/v1")!, authValue: "Bearer local-fixture")
            let result = try await recoverMeetingTurns(tracks: [track], turns: [original], directory: root.appendingPathComponent("recovery"),
                languages: ["es"], keywords: ["Fixture"], config: config, session: session, onPersist: { try state.persist($0) })
            try liveCheck(result.count == 2 && result[0] == original && result[1].start == 5 && result[1].end == 6,
                          "only actual missing range is recovered")
            let body = String(decoding: LiveRecoveryProtocol.requestBodies[0], as: UTF8.self)
            try liveCheck(body.contains("gpt-transcribe") && !body.contains("name=\"prompt\"") && !body.contains("diarized_json"),
                          "recovery does not enter dictation prompt or diarization")
            _ = try await recoverMeetingTurns(tracks: [track], turns: [original], directory: root.appendingPathComponent("recovery"),
                languages: ["es"], keywords: ["Fixture"], config: config, session: session, onPersist: { try state.persist($0) })
            try liveCheck(LiveRecoveryProtocol.requests.count == 1, "successful response cache survives retry")
            let gap = SessionAudioTrack(source: .mic, spans: [.init(url: audio, offset: 0, duration: 0.5), .init(url: audio, offset: 1, duration: 0.5)])
            do { try validateCapturedMeetingInterval(track: gap, start: 0, end: 1.5); throw LiveCheckFailure(name: "cannot seal padded silence") }
            catch let failure as LiveCheckFailure { throw failure } catch {}
        })
    ]
    var failures = 0
    for (name, test) in cases {
        do { try await test() }
        catch { failures += 1; let check = (error as? LiveCheckFailure)?.name ?? "fixture error"; FileHandle.standardError.write(Data(("live contract FAILED: " + name + " (" + check + ")\n").utf8)) }
    }
    return failures == 0
}
