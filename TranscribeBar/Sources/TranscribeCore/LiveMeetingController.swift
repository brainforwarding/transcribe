import Foundation

/// All queue offers are bounded and nonblocking. One consumer serializes protocol,
/// persistence, and completion processing; async callbacks cannot reorder saves.
public final class LiveMeetingController: @unchecked Sendable {
    public typealias SocketFactory = @Sendable (URLRequest) throws -> any LiveTranscriptionSocket
    public typealias Persist = @Sendable ([MeetingTurn]) async throws -> Void
    private enum Input: Sendable {
        case frame(CapturedAudioFrame), event(Source, UUID, LiveTranscriptionEvent), failure(Source, UUID, ServiceFailureKind)
        case overflow(Source), stop, deadline
    }
    private let lock = NSLock()
    private var queue: [Input] = []
    private var queuedSeconds: [Source: Double] = [:]
    private var overflowSources: Set<Source> = []
    private var accepting = true
    private var finishing = false
    private var started = false
    private var worker: Task<[MeetingTurn], Never>?
    private var stopTimer: Task<Void, Never>?
    private let signals: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    private let engine: Engine
    private let finishTimeout: UInt64
    public init(realtimeURL: URL, config: OpenAIConfig, sources: [Source], languages: [String] = [],
                keywords: [String] = [], onPersist: @escaping Persist,
                onDraft: @escaping @Sendable (LiveMeetingDraft) -> Void = { _ in },
                onIssue: @escaping @Sendable (TranscriptionIssue) -> Void = { _ in },
                socketFactory: SocketFactory? = nil, finishTimeout: TimeInterval = 10,
                model: LiveTranscriptionModel = .live, pauseAwareDictation: Bool = false) {
        self.finishTimeout = UInt64((finishTimeout.isFinite ? min(10, max(0.1, finishTimeout)) : 10) * 1_000_000_000)
        var continuation: AsyncStream<Void>.Continuation!
        signals = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation = $0 }
        signal = continuation
        engine = Engine(url: realtimeURL, config: config, sources: sources, languages: languages,
                        keywords: keywords, persist: onPersist, draft: onDraft, issue: onIssue,
                        factory: socketFactory ?? { NativeLiveSocket(request: $0, session: .shared) }, model: model,
                        pauseAwareDictation: pauseAwareDictation)
    }
    public func start() async {
        lock.withLock {
        guard !started, accepting else { return }; started = true
        worker = Task { [self] in
            await engine.start { [weak self] source, generation, event, failure in
                guard let self else { return }
                if let event { self.enqueue(.event(source, generation, event)) }
                if let failure { self.enqueue(.failure(source, generation, failure)) }
            }
            for await _ in signals {
                let batch = take()
                for input in batch {
                    await engine.handle(input)
                    if await engine.finished { signal.finish(); return await engine.shutdown() }
                }
            }
            return await engine.shutdown()
        }
        }
    }
    public func offer(_ frame: CapturedAudioFrame) {
        lock.withLock {
            guard accepting, frame.duration > 0 else { return }
            if (queuedSeconds[frame.source] ?? 0) + frame.duration > 2 {
                overflowSources.insert(frame.source)
            } else if !overflowSources.contains(frame.source) {
                queue.append(.frame(frame)); queuedSeconds[frame.source, default: 0] += frame.duration
            }
        }
        signal.yield(())
    }
    public func finish() async -> [MeetingTurn] {
        let task = lock.withLock { () -> Task<[MeetingTurn], Never>? in
            accepting = false
            if !finishing {
                finishing = true; queue.append(.stop)
                stopTimer = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: self?.finishTimeout ?? 10_000_000_000) } catch { return }
                    guard let self else { return }
                    await self.engine.closeTransport(); self.enqueue(.deadline)
                }
            }
            return worker
        }
        signal.yield(())
        let result = await task?.value ?? []
        takeStopTimer()?.cancel()
        return result
    }
    public func cancel() async -> [MeetingTurn] {
        let task = lock.withLock { () -> Task<[MeetingTurn], Never>? in
            accepting = false; finishing = true; queue.append(.deadline); return worker
        }
        takeStopTimer()?.cancel()
        await engine.closeTransport(); signal.yield(())
        return await task?.value ?? []
    }
    private func takeStopTimer() -> Task<Void, Never>? {
        lock.withLock { let task = stopTimer; stopTimer = nil; return task }
    }
    private func enqueue(_ input: Input) {
        lock.withLock {
            if queue.count > 256 {
                switch input {
                case .event(let source, _, _), .failure(let source, _, _): overflowSources.insert(source)
                default: queue.append(input)
                }
            } else { queue.append(input) }
        }
        signal.yield(())
    }
    private func take() -> [Input] {
        lock.withLock {
            let bad = overflowSources
            var batch = bad.sorted().map { Input.overflow($0) }
            // Invalidated frame batches are not uploaded in a truncated form.
            batch.append(contentsOf: queue.filter { input in
                if case .frame(let frame) = input { return !bad.contains(frame.source) }; return true
            })
            queue = []; queuedSeconds = [:]; overflowSources = []
            return batch
        }
    }

    private actor Engine {
        final class Connection {
            let generation = UUID()
            let socket: any LiveTranscriptionSocket
            let encoder = LivePCMEncoder()
            var receiving: Task<Void, Never>?
            var configuring: Task<Void, Never>?
            var ready = false
            var openedAt = Date()
            var expiresAt: Double?
            var beforeReady: [CapturedAudioFrame] = []
            var open: MeetingTurn?
            var recent: [CapturedAudioFrame] = []
            var replay: [CapturedAudioFrame] = []
            var lastSignalEnd: Double?
            var pcmFrames = 0
            var commitQueue: [Int] = []
            var itemMap: [String: Int] = [:]
            var previousItemID: String?
            var early: [String: [LiveTranscriptionEvent]] = [:]
            var drafts: [String: String] = [:]
            var lastDraftAt = Date.distantPast
            var sentEvents: Set<String> = []
            var completedItems: Set<String> = []
            init(socket: any LiveTranscriptionSocket) { self.socket = socket }
        }
        let url: URL
        let config: OpenAIConfig
        let sources: [Source]
        let languages: [String]
        let keywords: [String]
        let persist: Persist
        let draft: @Sendable (LiveMeetingDraft) -> Void
        let issue: @Sendable (TranscriptionIssue) -> Void
        let factory: SocketFactory
        let model: LiveTranscriptionModel
        let pauseAwareDictation: Bool
        var connections: [Source: Connection] = [:]
        var turns: [MeetingTurn] = []
        var ordinals: [Source: Int] = [:]
        var nextConnect: [Source: Date] = [:]
        var failures: [Source: Int] = [:]
        var blocked: Set<Source> = []
        var finishing = false
        var finished = false
        var receive: (@Sendable (Source, UUID, LiveTranscriptionEvent?, ServiceFailureKind?) -> Void)?
        init(url: URL, config: OpenAIConfig, sources: [Source], languages: [String], keywords: [String],
             persist: @escaping Persist, draft: @escaping @Sendable (LiveMeetingDraft) -> Void,
             issue: @escaping @Sendable (TranscriptionIssue) -> Void, factory: @escaping SocketFactory,
             model: LiveTranscriptionModel, pauseAwareDictation: Bool) {
            self.url = url; self.config = config; self.sources = sources; self.languages = languages; self.keywords = keywords
            self.persist = persist; self.draft = draft; self.issue = issue; self.factory = factory
            self.model = model
            self.pauseAwareDictation = pauseAwareDictation
        }
        func start(receive: @escaping @Sendable (Source, UUID, LiveTranscriptionEvent?, ServiceFailureKind?) -> Void) async {
            self.receive = receive
            for source in sources { await connect(source) }
        }
        private func connect(_ source: Source) async {
            guard !finishing, !blocked.contains(source), url.scheme == "wss", config.hasKey else { return }
            do {
                var request = URLRequest(url: url); request.timeoutInterval = 12
                request.setValue(config.authValue, forHTTPHeaderField: config.authName)
                let socket = try factory(request)
                let connection = Connection(socket: socket); connections[source] = connection
                let callback = receive, generation = connection.generation
                connection.receiving = Task {
                    do {
                        while !Task.isCancelled {
                            let event = try LiveTranscriptionEvent.parse(await socket.receive())
                            callback?(source, generation, event, nil)
                        }
                    } catch {
                        if !Task.isCancelled { callback?(source, generation, nil, (error as? ProviderError)?.failureKind ?? .unavailable) }
                    }
                }
                let id = UUID().uuidString; connection.sentEvents.insert(id)
                let configuration = try LiveProtocol.configuration(languages: languages, keywords: keywords, eventID: id, model: model)
                // A slow second handshake must not stall the first source's event
                // processing. Audio still waits for its own configuration ACK.
                connection.configuring = Task {
                    do { try await socket.send(configuration) }
                    catch {
                        if !Task.isCancelled { callback?(source, generation, nil, (error as? ProviderError)?.failureKind ?? .unavailable) }
                    }
                }
            } catch { await invalidate(source, failure: (error as? ProviderError)?.failureKind ?? .unavailable) }
        }
        func handle(_ input: Input) async {
            guard !finished else { return }
            switch input {
            case .frame(let frame): await append(frame)
            case .event(let source, let generation, let event):
                guard connections[source]?.generation == generation else { return }; await eventReceived(event, source: source)
            case .failure(let source, let generation, let failure):
                guard connections[source]?.generation == generation else { return }; await invalidate(source, failure: failure)
            case .overflow(let source): await invalidate(source, failure: .unavailable)
            case .stop:
                finishing = true
                for source in sources { await commit(source, stopping: true) }
            case .deadline:
                finishing = true
                for source in sources { await invalidate(source, failure: .unavailable, report: false) }
                finished = true
            }
            if finishing && connections.values.allSatisfy({ $0.open == nil && $0.commitQueue.isEmpty && $0.itemMap.isEmpty }) { finished = true }
        }
        private func append(_ frame: CapturedAudioFrame) async {
            guard !finishing, frame.offset.isFinite, frame.offset >= 0, frame.duration > 0 else { return }
            if connections[frame.source] == nil, !blocked.contains(frame.source), Date() >= (nextConnect[frame.source] ?? .distantPast) {
                await connect(frame.source)
            }
            guard let c = connections[frame.source] else { return } // raw coverage recovered at stop
            if !c.ready {
                if c.beforeReady.reduce(0, { $0 + $1.duration }) + frame.duration <= 2 { c.beforeReady.append(frame) }
                else { await invalidate(frame.source, failure: .unavailable) }
                return
            }
            if Date().timeIntervalSince(c.openedAt) > 2_940 || c.expiresAt.map({ Date().timeIntervalSince1970 >= $0 - 30 }) == true {
                await invalidate(frame.source, failure: nil, report: false)
                nextConnect[frame.source] = .distantPast; await connect(frame.source)
                await append(frame); return
            }
            if let open = c.open, abs(frame.offset - open.end) > 1 / 8_000 {
                // End at the last real sample and discard this generation's converter tail.
                await commit(frame.source, stopping: true, reason: .discontinuity)
                guard connections[frame.source] === c else { return }
                c.encoder.reset(); c.recent = []; c.replay = []
            }
            var prefix: [CapturedAudioFrame] = []
            if c.open == nil {
                let idx = ordinals[frame.source] ?? (frame.source.rawValue * 1_000_000_000)
                ordinals[frame.source] = idx + 1
                if pauseAwareDictation, let last = c.replay.last,
                   abs(last.offset + last.duration - frame.offset) <= 1 / 8_000 { prefix = c.replay }
                c.replay = []
                c.open = MeetingTurn(idx: idx, source: frame.source, start: prefix.first?.offset ?? frame.offset, end: frame.offset + frame.duration)
                c.pcmFrames = 0; c.lastSignalEnd = nil
            } else { c.open?.end = frame.offset + frame.duration }
            if frame.rms > LiveProtocol.signalRMS { c.lastSignalEnd = frame.offset + frame.duration }
            do {
                for context in prefix {
                    let bytes = try c.encoder.encode(context)
                    if !bytes.isEmpty { try await sendAudio(bytes, source: frame.source, connection: c) }
                }
                let encoded = try c.encoder.encode(frame)
                if !encoded.isEmpty { try await sendAudio(encoded, source: frame.source, connection: c) }
                guard connections[frame.source] === c, let open = c.open else { return }
                if pauseAwareDictation {
                    c.recent.append(frame)
                    let cutoff = open.end - 2
                    c.recent.removeAll { $0.offset + $0.duration <= cutoff }
                    if let first = c.recent.first, first.offset < cutoff {
                        let drop = min(first.pcmFloat32.count / 4, Int(((cutoff - first.offset) * 16_000).rounded()))
                        c.recent[0] = CapturedAudioFrame(source: first.source, offset: first.offset + Double(drop) / 16_000,
                            pcmFloat32: Data(first.pcmFloat32.dropFirst(drop * 4)), rms: first.rms)
                    }
                }
                let duration = open.end - open.start
                let quiet = c.lastSignalEnd.map { open.end - $0 } ?? (pauseAwareDictation ? duration : 0)
                // After the 10 s target, prefer even a short pause over cutting speech.
                let requiredQuiet = pauseAwareDictation && duration >= 10 ? 0.3 : LiveProtocol.quietCommitDuration
                let paused = quiet >= requiredQuiet && duration >= LiveProtocol.minimumCommitDuration
                if paused || duration >= (pauseAwareDictation ? 20 : LiveProtocol.maximumTurnDuration) {
                    await commit(frame.source, stopping: false, reason: paused ? .pause : .forced)
                }
            } catch { await invalidate(frame.source, failure: (error as? ProviderError)?.failureKind ?? .unavailable) }
        }
        private func sendAudio(_ data: Data, source: Source, connection c: Connection) async throws {
            // Frame-size bound remains well below the relay maximum even for unusual capture batches.
            for offset in stride(from: 0, to: data.count, by: 9_600) {
                let bytes = data.subdata(in: offset..<min(data.count, offset + 9_600))
                let id = UUID().uuidString; c.sentEvents.insert(id)
                if c.sentEvents.count > 2_048 { throw ProviderError.invalidResponse }
                try await c.socket.send(LiveProtocol.event("input_audio_buffer.append", id: id, audio: bytes))
                guard connections[source] === c else { throw ProviderError.unavailable }
                c.pcmFrames += bytes.count / 2
            }
        }
        private func commit(_ source: Source, stopping: Bool, reason: MeetingTurn.EndReason = .stopped) async {
            guard let c = connections[source], var open = c.open else { return }
            do {
                // Seal the resampler tail into THIS interval. Carrying its filter
                // state into the next item would hide unsubmitted confirmed audio.
                let tail = try c.encoder.finish()
                if !tail.isEmpty { try await sendAudio(tail, source: source, connection: c) }
                guard connections[source] === c else { return }
                let count = c.commitQueue.count + c.itemMap.count
                if open.end - open.start < LiveProtocol.minimumCommitDuration || c.pcmFrames < 6_000 || count >= 4 {
                    await invalidate(source, failure: .unavailable, report: false); return
                }
                open.state = .pending
                open.endReason = reason
                let next = turns + [open]
                try await persist(next); turns = next
                c.open = nil; c.pcmFrames = 0; c.lastSignalEnd = nil
                c.replay = pauseAwareDictation && reason == .forced ? c.recent : []
                c.recent = []
                c.commitQueue.append(open.idx)
                let id = UUID().uuidString; c.sentEvents.insert(id)
                try await c.socket.send(LiveProtocol.event("input_audio_buffer.commit", id: id))
                c.encoder.reset()
            } catch { await invalidate(source, failure: (error as? ProviderError)?.failureKind ?? .storage) }
        }
        private func eventReceived(_ event: LiveTranscriptionEvent, source: Source) async {
            guard let c = connections[source] else { return }
            switch event.type {
            case "session.created", "session.updated", "transcription_session.created", "transcription_session.updated":
                if let expiry = event.expiresAt { c.expiresAt = expiry }
                if event.type.hasSuffix(".updated") {
                    c.ready = true
                    let frames = c.beforeReady; c.beforeReady = []
                    for frame in frames { await append(frame) }
                }
            case "error", "conversation.item.input_audio_transcription.failed":
                // There is no ACK after a rejected commit. Even with an associated
                // event_id, fail the generation closed rather than shift its FIFO.
                await invalidate(source, failure: event.failure ?? .invalidResponse)
            case "input_audio_buffer.committed":
                guard let item = event.itemID, !item.isEmpty, event.hasPreviousItemID,
                      event.previousItemID == c.previousItemID, !c.commitQueue.isEmpty,
                      c.itemMap[item] == nil else { await invalidate(source, failure: .invalidResponse); return }
                let idx = c.commitQueue.removeFirst(); c.itemMap[item] = idx; c.previousItemID = item
                // Append events are no longer useful for association after a valid ACK.
                c.sentEvents = []
                let early = c.early.removeValue(forKey: item) ?? []
                c.drafts.removeValue(forKey: item)
                for buffered in early { await eventReceived(buffered, source: source) }
            case "conversation.item.input_audio_transcription.delta", "conversation.item.input_audio_transcription.completed":
                guard let item = event.itemID, !item.isEmpty, let text = event.text, text.utf8.count <= 65_536 else {
                    await invalidate(source, failure: .invalidResponse); return
                }
                if c.completedItems.contains(item) { return }
                guard let idx = c.itemMap[item] else {
                    // A delta may precede commit acknowledgment. It is a draft with
                    // source provenance only, never a confirmed/timed passage.
                    guard c.early.count < 8 || c.early[item] != nil,
                          c.early.values.reduce(0, { $0 + $1.count }) < 128,
                          c.early.values.flatMap({ $0 }).reduce(0, { $0 + ($1.text?.utf8.count ?? 0) }) + text.utf8.count <= 131_072
                    else { await invalidate(source, failure: .invalidResponse); return }
                    c.early[item, default: []].append(event)
                    if event.type.hasSuffix(".delta") {
                        let combined = (c.drafts[item] ?? "") + text
                        guard combined.utf8.count <= 65_536 else { await invalidate(source, failure: .invalidResponse); return }
                        c.drafts[item] = combined; emitDraft(source: source, item: item, connection: c)
                    }
                    return
                }
                guard let position = turns.firstIndex(where: { $0.idx == idx }), turns[position].state != .confirmed else { return }
                if event.type.hasSuffix(".delta") {
                    let combined = (c.drafts[item] ?? "") + text
                    guard combined.utf8.count <= 65_536 else { await invalidate(source, failure: .invalidResponse); return }
                    c.drafts[item] = combined; emitDraft(source: source, item: item, connection: c)
                } else {
                    var next = turns; next[position].state = .confirmed; next[position].text = text; next[position].failureKind = nil
                    do { try await persist(next); turns = next; failures[source] = 0 }
                    catch { await invalidate(source, failure: .storage); return }
                    c.itemMap.removeValue(forKey: item); c.drafts.removeValue(forKey: item)
                    c.completedItems.insert(item)
                    if c.completedItems.count > 1_024 { await invalidate(source, failure: nil, report: false) }
                    draft(.init(source: source, itemID: item, text: ""))
                }
            default: break
            }
        }
        private func emitDraft(source: Source, item: String, connection: Connection) {
            guard Date().timeIntervalSince(connection.lastDraftAt) >= 0.1 else { return }
            connection.lastDraftAt = Date()
            draft(.init(source: source, itemID: item, text: connection.drafts[item] ?? ""))
        }
        private func invalidate(_ source: Source, failure: ServiceFailureKind?, report: Bool = true) async {
            guard let c = connections.removeValue(forKey: source) else { return }
            c.socket.close(); c.receiving?.cancel(); c.configuring?.cancel()
            var next = turns
            if var open = c.open { open.state = .needsRecovery; open.failureKind = failure; next.append(open) }
            for i in next.indices where next[i].source == source && next[i].state != .confirmed {
                next[i].state = .needsRecovery; next[i].failureKind = failure
            }
            do { try await persist(next); turns = next }
            catch { blocked.insert(source); issue(.init(source: source, userMessage: "Meeting words could not be saved. Audio is retained.", failureKind: .storage)) }
            for item in c.drafts.keys { draft(.init(source: source, itemID: item, text: "")) }
            if failure?.allowsRecoveryAfterRemedy == true || failure == .invalidHints { blocked.insert(source) }
            failures[source, default: 0] += 1
            nextConnect[source] = Date().addingTimeInterval(min(30, pow(2, Double(min(5, failures[source] ?? 1)))))
            if report { issue(.init(source: source, userMessage: "Live transcript paused. Recording continues and saved audio can be retried.", failureKind: failure ?? .unavailable)) }
        }
        func closeTransport() { finishing = true; for c in connections.values { c.socket.close() } }
        func shutdown() async -> [MeetingTurn] {
            for source in sources { await invalidate(source, failure: .unavailable, report: false) }
            return turns
        }
    }
}
