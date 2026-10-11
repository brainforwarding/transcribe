import Foundation
import TranscribeCore
import Security

/// Requests are intercepted before any network operation or real credential access.
private final class ProviderProbeProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var replies: Int? = 200
    private static var recorded: [URLRequest] = []
    private static var pending: [ProviderProbeProtocol] = []
    static var requests: [URLRequest] { lock.withLock { recorded } }
    static func reset(status: Int? = 200) { lock.withLock { replies = status; recorded = []; pending = [] } }
    static func finish(status: Int) {
        let waiting = lock.withLock { let waiting = pending; pending = []; return waiting }
        waiting.forEach { $0.respond(status) }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status = Self.lock.withLock { () -> Int? in
            Self.recorded.append(request)
            if Self.replies == nil { Self.pending.append(self) }
            return Self.replies
        }
        if let status { respond(status) }
    }
    private func respond(_ status: Int) {
        if status == -1 {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"id":"local-model-fixture"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Standalone CLT runner. Every command under test is the actual AppModel command.
@MainActor
private final class Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var entered = false
    func wait() async {
        entered = true
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume(); continuation = nil
    }
}

private struct CheckFailure: Error, CustomStringConvertible { let description: String }
@MainActor
private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure(description: message) }
}
@MainActor
private func until(_ message: String, _ condition: () -> Bool) async throws {
    for _ in 0..<10_000 {
        if condition() { return }
        await Task.yield()
    }
    throw CheckFailure(description: "Completion did not arrive: " + message)
}

@MainActor
private final class Fixture {
    let folder: URL
    let store: SessionStore
    let preferenceDomain = "Transcribe.CoordinatorTests." + UUID().uuidString
    let preferences: UserDefaults
    let credentialVault: CredentialVault
    let credentialAccess: CredentialAccess
    let verificationSession: URLSession
    var seenProvider: ConnectionProvider?
    var seenConfig: OpenAIConfig?
    var seenFormattingConfig: OpenAIConfig?
    let startup = Gate()
    let processing = Gate()
    let delivery = Gate()
    let formatting = Gate()
    var formatterEnabled = false
    var blocksFormatting = false
    var formattingCancelled = false
    var formatterRequests = 0
    var rawSavedBeforeFormatting = false
    var formattedSaveFails = false
    var cancellationSaveFails = false
    var formattedText = "Saved speech."
    var formatFailure: ServiceFailureKind? = nil
    var transcriptionFailure: ServiceFailureKind? = nil
    var finalText = "Saved speech"
    var finalComplete = true
    var blocksDelivery = false
    var currentFocus = "Field A"
    var deliveredFocus: String?
    var deliveryWrites = 0
    var deliveryCompletions = 0
    var model: AppModel!
    var now = 10_000.0
    var starts = 0
    var stops = 0
    var transcriptionRequests = 0
    var insertions = 0
    var manualPastes = 0
    var copies = 0
    var copyResult = true
    var cleanups = 0
    var cleanupFails = false
    var finalSaveFails = false
    var recordingSaveFails = false
    var stopSaveFails = false
    var artifact: URL?
    var insertedAfterDurableText = false
    var automaticOutcome: PasteService.Outcome = .inserted
    var manualOutcome: PasteService.Outcome = .inserted
    var livePersist: LiveMeetingController.Persist?
    var liveIssue: (@Sendable (TranscriptionIssue) -> Void)?
    var liveDraft: (@Sendable (LiveMeetingDraft) -> Void)?
    var liveRecoveries = 0
    var liveConfirmedSaveFails = false
    var recoveredInput: [MeetingTurn] = []
    var levelCallback: (@Sendable (Source, Double) -> Void)?

    init(legacyCredential: CredentialSession.ReadResult = .missing, storedProvider: ConnectionProvider? = nil,
         existingConsent: Bool = false, liveMeetingEnabled: Bool = false,
         directCredential: CredentialSession.ReadResult = .value("local-test-direct")) throws {
        credentialVault = CredentialVault(read: { provider, _ in provider == .team ? legacyCredential : directCredential },
                                          write: { _, _ in })
        let vault = credentialVault
        credentialAccess = CredentialAccess(get: { vault.get($0) }, unlock: { vault.unlock($0) },
            set: { try vault.set($0, for: $1) }, status: { vault.status($0) }, fingerprint: { vault.fingerprint($0) },
            legacyConfigured: { _ = vault.get(.team); return vault.status(.team) != errSecItemNotFound })
        ProviderProbeProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderProbeProtocol.self]
        verificationSession = URLSession(configuration: configuration)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("transcribe-coordinator-" + UUID().uuidString)
        store = try SessionStore(root: folder.appendingPathComponent("sessions"))
        preferences = UserDefaults(suiteName: preferenceDomain)!
        if let storedProvider { preferences.set(storedProvider.rawValue, forKey: "connectionProvider") }
        preferences.set(existingConsent, forKey: "consentAccepted")
        preferences.set(false, forKey: "keepAudio")
        preferences.set(false, forKey: "includeSummary")
        preferences.set(folder.appendingPathComponent("exports").path, forKey: "saveFolderPath")
        var operations = AppModel.Operations(makeCapture: { [self] directory, _, _, level, _, _ in
            let raw = directory.appendingPathComponent("mic-test.wav")
            // Fake capture has real owned recovery data so cleanup assertions inspect disk.
            try! Data("owned recovery audio fixture".utf8).write(to: raw)
            let track = SessionAudioTrack(source: .mic, spans: [AudioSpan(url: raw, offset: 0, duration: 2)])
            try! JSONEncoder().encode(track).write(to: directory.appendingPathComponent("mic-capture.json"))
            artifact = raw; levelCallback = level
            return AppModel.CaptureSession(start: { [self] in
                starts += 1; await startup.wait()
            }, stop: { [self] in
                stops += 1
                return AppModel.CaptureSession.Output(tracks: [SessionAudioTrack(source: .mic,
                    spans: [AudioSpan(url: raw, offset: 0, duration: 2)])], issues: [])
            }, retrySystemAudio: {})
        }, transcribe: { [self] _, _, config in
            seenConfig = config
            transcriptionRequests += 1; await processing.wait()
            return FinalTranscription(text: finalText, segments: [], complete: finalComplete && transcriptionFailure == nil,
                issues: transcriptionFailure.map { [TranscriptionIssue(userMessage: "Safe fixture failure", retryable: false, failureKind: $0)] } ?? [])
        }, uptime: { [self] in now }, credentials: { [self] provider in
            seenProvider = provider
            guard let credential = credentialVault.get(provider) else { throw CheckFailure(description: "Missing synthetic credential") }
            return OpenAIConfig(baseURL: provider.baseURL, authValue: "Bearer " + credential)
        }, save: { [self] store, record in
            if liveConfirmedSaveFails && record.meetingTurns.contains(where: { $0.state == .confirmed }) { throw CocoaError(.fileWriteOutOfSpace) }
            if recordingSaveFails && record.status == .recording { throw CocoaError(.fileWriteOutOfSpace) }
            if stopSaveFails && !record.tracks.isEmpty && !record.hasText { throw CocoaError(.fileWriteOutOfSpace) }
            if finalSaveFails && record.status == .complete && record.hasText { throw CocoaError(.fileWriteOutOfSpace) }
            if formattedSaveFails && record.transcript == formattedText { throw CocoaError(.fileWriteOutOfSpace) }
            if cancellationSaveFails && record.status == .cancelled { throw CocoaError(.fileWriteOutOfSpace) }
            try store.save(record)
        }, cleanAudio: { [self] store, record in
            cleanups += 1; if cleanupFails { throw CocoaError(.fileWriteNoPermission) }; try store.cleanAudio(for: record)
        }, deliverAtCurrentCaret: { [self] text, canDeliver in
            let automatic = model.phase == .transcribing
            let target = currentFocus
            if automatic {
                insertions += 1
                insertedAfterDurableText = (try? store.load().first?.transcript) == text
            } else { manualPastes += 1 }
            defer { deliveryCompletions += 1 }
            if blocksDelivery { await delivery.wait() }
            guard canDeliver() else { return .ready(reason: "Delivery was cancelled.") }
            guard currentFocus == target else { return .ready(reason: "The focused field changed before paste.") }
            deliveryWrites += 1; deliveredFocus = target
            return automatic ? automaticOutcome : manualOutcome
        },
        copy: { [self] _ in copies += 1; return copyResult }, automaticTimer: false, format: { [self] raw, config in
            guard formatterEnabled else { return DictationFormatResult(text: raw) }
            formatterRequests += 1
            seenFormattingConfig = config
            let saved = try store.load().first
            rawSavedBeforeFormatting = saved?.transcript == raw && saved?.rawTranscript == raw &&
                seenConfig?.baseURL == config.baseURL && seenConfig?.authValue == config.authValue
            if blocksFormatting { await formatting.wait() }
            if formattingCancelled { throw CancellationError() }
            return DictationFormatResult(text: formattedText, failure: formatFailure)
        })
        if liveMeetingEnabled {
            operations.makeLiveMeeting = { [self] _, _, _, persist, draft, issue in
                livePersist = persist; liveDraft = draft; liveIssue = issue
                return AppModel.MeetingSession(start: {}, offer: { _ in }, finish: { [] }, cancel: { [] })
            }
            operations.recoverMeeting = { [self] record, _, _, persist in
                liveRecoveries += 1; recoveredInput = record.meetingTurns
                var turns = record.meetingTurns
                let planned = planMeetingRecovery(tracks: record.tracks, turns: turns)
                turns = planned.map { turn in
                    if turn.state == .confirmed { return turn }
                    var recovered = turn; recovered.state = .confirmed; recovered.text = "Recovered only missing"; return recovered
                }
                try await persist(turns); return turns
            }
        }
        model = AppModel(store: store, operations: operations, preferences: preferences, initializeSystemState: false,
            credentialAccess: credentialAccess, verificationSession: verificationSession)
        model.micGranted = true; model.acceptConsent()
    }
    func close() async {
        startup.release(); processing.release(); delivery.release(); formatting.release()
        await model?.prepareToQuit()
        model = nil; verificationSession.invalidateAndCancel()
        preferences.removePersistentDomain(forName: preferenceDomain)
        try? FileManager.default.removeItem(at: folder)
    }
    func beginRecording() async throws {
        model.startDictation(); startup.release()
        try await until("recording") { model.phase == .recording }
    }
    func beginProcessing() async throws {
        try await beginRecording(); model.finishRecording()
        try await until("processing request") { processing.entered }
    }
    func pasteLast() async throws {
        let previous = deliveryCompletions
        model.pasteLast()
        try await until("manual paste completion") { deliveryCompletions > previous }
    }
    func audioExists() -> Bool { artifact.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
    func addFormattingRecord(failure: ServiceFailureKind = .unavailable) throws -> UUID {
        var record = SessionRecord(kind: .dictation, title: "Synthetic formatter retry")
        record.status = .complete; record.delivery = .inserted
        record.transcript = "Saved speech"; record.rawTranscript = "Saved speech"
        record.formattingFailure = failure; record.serviceProviderID = ConnectionProvider.openAI.rawValue
        try store.save(record); model.records = try store.load()
        return record.id
    }
    func addHistoricalRecord(status: SessionStatus = .complete) throws -> UUID {
        var record = SessionRecord(kind: .dictation, title: "Earlier dictation", startedAt: Date(timeIntervalSince1970: 1))
        record.status = status; record.delivery = .ready; record.transcript = status == .complete ? "Earlier text" : ""
        try store.save(record)
        let raw = store.directory(for: record.id).appendingPathComponent("history.wav")
        try Data("historical owned audio".utf8).write(to: raw)
        record.tracks = [SessionAudioTrack(source: .mic, spans: [AudioSpan(url: raw, offset: 0, duration: 2)])]
        try store.save(record); model.records.append(record)
        return record.id
    }
}

@main
struct CoordinatorSelftest {
    @MainActor static func main() async {
        let cases: [(String, @MainActor (Fixture) async throws -> Void)] = [
            ("Copy feedback requires a successful clipboard write", { f in
                try check(!f.model.copyTranscript(UUID()) && f.copies == 0, "Missing record must not claim copy success")
                let emptyID = try f.addHistoricalRecord(status: .failed)
                try check(!f.model.copyTranscript(emptyID) && f.copies == 0, "Empty record must not write or claim copy success")
                let textID = try f.addHistoricalRecord()
                f.copyResult = false
                try check(!f.model.copyTranscript(textID) && f.copies == 1, "Failed clipboard write must propagate false")
                f.copyResult = true
                try check(f.model.copyTranscript(textID) && f.copies == 2, "Successful clipboard write must propagate true")
            }),
            ("Formatter failure persists separately and raw text still delivers", { f in
                f.formatterEnabled = true; f.formattedText = "Saved speech"; f.formatFailure = .unavailable
                try await f.beginProcessing(); f.processing.release()
                try await until("formatter fallback delivery") { f.model.phase == .done }
                let record = try f.store.load().first!
                try check(record.status == .complete && record.formattingFailure == .unavailable &&
                          record.transcript == "Saved speech" && record.rawTranscript == "Saved speech" &&
                          record.transcriptionIssues.isEmpty && f.deliveryWrites == 1 && f.copies == 0,
                          "Formatter failure must keep raw successful ASR and normal delivery")
                try check(f.model.serviceNotice(for: record)?.action == .retryFormatting &&
                          f.model.canRetryFormatting(record), "Formatting must offer a distinct text-only retry")
            }),
            ("Manual formatting retry preserves coordinator and insertion history", { f in
                f.formatterEnabled = true; f.blocksFormatting = true
                let id = try f.addFormattingRecord()
                let phase = f.model.phase; let activeID = f.model.activeSessionID
                f.model.retryFormatting(id)
                try await until("manual formatting entry") { f.formatting.entered }
                try check(f.model.isBusy && f.model.formattingRecordID == id && f.model.phase == phase &&
                          f.model.activeSessionID == activeID, "Dedicated formatting must not reinterpret capture state")
                f.model.retryFormatting(id); f.model.startDictation(); f.model.pasteLast(); f.model.setConnectionProvider(.team)
                try check(f.formatterRequests == 1 && f.starts == 0 && f.manualPastes == 0 &&
                          f.model.connectionProvider == .openAI, "Formatting must serialize capture, paste, provider switches and retries")
                f.formatting.release(); try await until("manual formatting completion") { f.model.formattingRecordID == nil }
                let saved = try f.store.load().first!
                try check(saved.transcript == f.formattedText && saved.rawTranscript == "Saved speech" &&
                          saved.formattingFailure == nil && saved.status == .complete && saved.delivery == .inserted &&
                          f.model.phase == phase && f.model.activeSessionID == activeID && f.transcriptionRequests == 0 &&
                          f.deliveryWrites == 0 && f.insertions == 0 && f.cleanups == 0 && f.copies == 0,
                          "Manual formatting can commit only text/failure, never ASR, insertion or cleanup")
                try check(f.seenFormattingConfig?.baseURL == ConnectionProvider.openAI.baseURL,
                          "Manual formatter must use the selected-provider config snapshot")
            }),
            ("Cancelling manual formatting retains prior durable text and failure", { f in
                f.formatterEnabled = true; f.blocksFormatting = true
                let id = try f.addFormattingRecord(); f.model.retryFormatting(id)
                try await until("cancel manual entry") { f.formatting.entered }
                f.model.cancelFormattingRetry(); f.formatting.release()
                try await until("cancel manual completion") { f.model.formattingRecordID == nil }
                let record = try f.store.load().first!
                try check(record.transcript == "Saved speech" && record.formattingFailure == .unavailable &&
                          record.delivery == .inserted && f.deliveryWrites == 0 && f.model.phase == .idle,
                          "Late formatter output must not overwrite a cancelled manual attempt")
            }),
            ("Manual formatting rejects stale text and leaves failed commits unchanged", { f in
                f.formatterEnabled = true; f.blocksFormatting = true
                let id = try f.addFormattingRecord(); f.model.retryFormatting(id)
                try await until("stale manual entry") { f.formatting.entered }
                var changed = f.model.records.first!; changed.transcript = "Edited text"
                try f.store.save(changed); f.model.records[0] = changed
                f.formatting.release(); try await until("stale manual completion") { f.model.formattingRecordID == nil }
                let staleSaved = try f.store.load().first!
                try check(staleSaved.transcript == "Edited text", "Stale output cannot overwrite newer text")
                changed.transcript = "Saved speech"; try f.store.save(changed); f.model.records[0] = changed
                f.formattedSaveFails = true; f.model.retryFormatting(id)
                try await until("manual save failure") { f.model.formattingRecordID == nil }
                let record = try f.store.load().first!
                try check(record.transcript == "Saved speech" && record.formattingFailure == .unavailable &&
                          f.deliveryWrites == 0 && f.cleanups == 0, "Failed manual commits must preserve original durable content")
            }),
            ("Quit cancels pending manual formatting without changing history", { f in
                f.formatterEnabled = true; f.blocksFormatting = true
                let id = try f.addFormattingRecord(); f.model.retryFormatting(id)
                try await until("quit manual entry") { f.formatting.entered }
                var quitStarted = false
                let quitting = Task { @MainActor in quitStarted = true; await f.model.prepareToQuit() }
                try await until("quit cancellation started") { quitStarted }
                f.formatting.release(); await quitting.value
                let record = try f.store.load().first!
                try check(f.model.formattingRecordID == nil && !f.model.isBusy &&
                          record.transcript == "Saved speech" && record.formattingFailure == .unavailable &&
                          record.delivery == .inserted && f.transcriptionRequests == 0 && f.deliveryWrites == 0 && f.cleanups == 0,
                          "Quit must clear pending formatting and preserve durable history with no other operation")
            }),
            ("Typed empty ASR credential failures stay actionable and recover after remedy", { f in
                f.finalText = ""; f.transcriptionFailure = .invalidCredential
                try await f.beginProcessing(); f.processing.release()
                try await until("account ASR failure") { f.model.phase == .done }
                let record = f.model.activeRecord!
                try check(record.status == .partial && record.canRecover && !record.hasText &&
                          f.model.serviceNotice(for: record)?.action == .settings,
                          "Empty account failures must retain their account action and saved audio recovery")
                f.transcriptionFailure = nil; f.finalText = "Saved speech"; f.model.retry(record.id)
                try await until("account ASR recovery") { f.model.phase == .done && f.transcriptionRequests == 2 }
                try check(f.model.activeRecord?.status == .complete && f.insertions == 0,
                          "Retry after remedy uses saved audio without automatic insertion")
            }),
            ("Account advice uses persisted provider and prefers account repair", { f in
                let id = try f.addFormattingRecord(failure: .insufficientCredits)
                var record = f.model.records.first!
                f.model.setConnectionProvider(.team)
                try check(f.model.serviceNotice(for: record)?.buttonTitle == "Add credits" &&
                          f.model.serviceNotice(for: record)?.action == .billing,
                          "Changing selected provider cannot redirect old OpenAI credit advice")
                record.serviceProviderID = "team"
                try check(f.model.serviceNotice(for: record)?.buttonTitle == "Settings" &&
                          f.model.serviceNotice(for: record)?.action == .settings, "Team credits cannot direct users to personal billing")
                record.serviceProviderID = nil
                try check(f.model.serviceNotice(for: record)?.action == .settings, "Legacy unknown accounts need neutral Settings advice")
                record.serviceProviderID = "openAI"; record.formattingFailure = .billingLimit
                try check(f.model.serviceNotice(for: record)?.buttonTitle == "Check billing", "Limits must not falsely claim exhausted credits")
                record.transcriptionIssues = [TranscriptionIssue(userMessage: "Unavailable", failureKind: .unavailable),
                    TranscriptionIssue(userMessage: "Access", failureKind: .accessDenied)]
                try check(f.model.serviceNotice(for: record)?.action == .settings, "Account setup should outrank transient retry")
                record.transcriptionIssues = [TranscriptionIssue(userMessage: "Too large", retryable: false, failureKind: .tooLarge)]
                try check(f.model.serviceNotice(for: record)?.action == nil,
                          "App-controlled oversized chunks cannot offer an irrelevant Settings remedy")
                _ = id
            }),
            ("Legacy raw and successful unchanged text cannot trigger formatter retry", { f in
                f.formatterEnabled = true
                _ = try f.addHistoricalRecord(); var record = f.model.records.first!
                record.formattingFailure = .unavailable
                try check(!f.model.canRetryFormatting(record), "Legacy nil raw text must never be invented")
                record.rawTranscript = record.transcript; record.formattingFailure = nil
                try check(!f.model.canRetryFormatting(record), "Successful unchanged text has no failed formatting to retry")
            }),
            ("Formatter saves raw first and accepted paragraphs before current-caret delivery", { f in
                f.formatterEnabled = true; f.blocksFormatting = true
                f.formattedText = "Saved\n\nspeech."
                try await f.beginProcessing(); f.processing.release()
                try await until("formatter entry") { f.formatting.entered }
                try check(f.rawSavedBeforeFormatting && f.insertions == 0 && f.model.phase == .transcribing,
                          "Raw text must be durable and credentials shared before formatting or insertion")
                f.currentFocus = "Final field"; f.formatting.release()
                try await until("formatted completion") { f.model.phase == .done }
                let saved = try f.store.load().first
                try check(saved?.rawTranscript == "Saved speech" && saved?.transcript == f.formattedText &&
                          f.insertedAfterDurableText && f.deliveredFocus == "Final field",
                          "Accepted paragraphs must be saved before completion-focus delivery")
                var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved!)) as! [String: Any]
                legacy.removeValue(forKey: "rawTranscript")
                let decoded = try JSONDecoder().decode(SessionRecord.self, from: JSONSerialization.data(withJSONObject: legacy))
                try check(decoded.rawTranscript == nil && decoded.transcript == f.formattedText,
                          "Legacy records must decode without inventing a raw transcript")
            }),
            ("Escape during formatting retains raw without late delivery or cleanup", { f in
                f.formatterEnabled = true; f.blocksFormatting = true
                try await f.beginProcessing(); f.processing.release()
                try await until("formatter cancellation entry") { f.formatting.entered }
                f.model.cancelDictation(); f.formatting.release()
                try await until("formatter cancelled completion") { f.model.phase == .done }
                let saved = try f.store.load().first
                try check(saved?.status == .cancelled && saved?.transcript == "Saved speech" &&
                          saved?.rawTranscript == "Saved speech" && f.insertions == 0 && f.cleanups == 0 && f.audioExists(),
                          "Late formatter output must not overwrite or insert a cancelled transcript")
            }),
            ("Formatter cancellation error after Escape reaches done", { f in
                f.formatterEnabled = true; f.blocksFormatting = true; f.formattingCancelled = true
                try await f.beginProcessing(); f.processing.release()
                try await until("formatter cancelled request") { f.formatting.entered }
                f.model.cancelDictation(); f.formatting.release()
                try await until("formatter cancellation error") { f.model.phase == .done }
                try check(f.model.activeRecord?.delivery == .cancelled && f.insertions == 0 && f.cleanups == 0 &&
                          f.model.activeRecord?.issues.isEmpty == true,
                          "Cancellation must finish without an unavailable warning or lost raw text")
            }),
            ("Failed Escape persistence still shows Cancelled and blocks delivery", { f in
                f.formatterEnabled = true; f.blocksFormatting = true
                try await f.beginProcessing(); f.processing.release()
                try await until("failed cancellation persistence entry") { f.formatting.entered }
                f.cancellationSaveFails = true; f.model.cancelDictation(); f.formatting.release()
                try await until("failed cancellation persistence completion") { f.model.phase == .done }
                try check(f.model.chipState == .cancelled && f.insertions == 0 && f.cleanups == 0 && f.audioExists() &&
                          f.model.activeRecord?.transcript == "Saved speech",
                          "The in-memory cancellation latch must own feedback despite failed durable cancellation")
            }),
            ("Formatted save failure keeps durable raw and audio with zero insertion", { f in
                f.formatterEnabled = true; f.formattedSaveFails = true
                try await f.beginProcessing(); f.processing.release()
                try await until("formatted save failure") { f.model.phase == .error }
                let saved = try f.store.load().first
                try check(saved?.transcript == "Saved speech" && saved?.rawTranscript == "Saved speech" &&
                          f.model.activeRecord?.transcript == "Saved speech" && f.insertions == 0 && f.cleanups == 0 && f.audioExists(),
                          "Unsaved formatted content must never be pasted or remove recovery audio")
            }),
            ("Raw save failure prevents formatter invocation", { f in
                f.formatterEnabled = true; f.finalSaveFails = true
                try await f.beginProcessing(); f.processing.release()
                try await until("raw save failure") { f.model.phase == .error }
                try check(f.formatterRequests == 0 && f.insertions == 0 && f.audioExists(),
                          "Formatting cannot begin before raw content is durably committed")
            }),
            ("Partial dictation bypasses formatting", { f in
                f.formatterEnabled = true; f.finalComplete = false
                try await f.beginProcessing(); f.processing.release()
                try await until("partial completion") { f.model.phase == .done }
                try check(f.formatterRequests == 0 && f.insertions == 0 && f.model.activeRecord?.transcript == "Saved speech",
                          "Incomplete transcripts must retain their existing behavior")
            }),
            ("Empty dictation bypasses formatting", { f in
                f.formatterEnabled = true; f.finalText = " \n"
                try await f.beginProcessing(); f.processing.release()
                try await until("empty completion") { f.model.phase == .done }
                try check(f.formatterRequests == 0 && f.insertions == 0 && f.model.chipState == .silent,
                          "Empty dictation must not call the formatter")
            }),
            ("Meeting transcript remains unformatted and has no raw dictation field", { f in
                f.formatterEnabled = true; f.model.meetingMode = .inPerson
                f.model.startMeeting(); f.startup.release()
                try await until("meeting recording") { f.model.phase == .recording }
                f.model.finishRecording(); try await until("meeting processing") { f.processing.entered }
                f.processing.release(); try await until("meeting completion") { f.model.phase == .done }
                let saved = try f.store.load().first
                try check(f.formatterRequests == 0 && f.insertions == 0 && saved?.transcript == "Saved speech" &&
                          saved?.rawTranscript == nil && saved?.kind == .meeting,
                          "Meetings must retain their existing transcription and export path")
            }),
            ("Raw formatter fallback retains normal durable insertion", { f in
                f.formatterEnabled = true; f.formattedText = "Saved speech"
                try await f.beginProcessing(); f.processing.release()
                try await until("fallback completion") { f.model.phase == .done }
                try check(f.formatterRequests == 1 && f.insertedAfterDurableText && f.deliveryWrites == 1 &&
                          f.model.activeRecord?.transcript == "Saved speech" && f.model.statusDetail.isEmpty,
                          "Silent fallback must deliver the already durable raw transcript normally")
            }),
            ("Historical retry may format but never inserts automatically", { f in
                f.formatterEnabled = true
                let id = try f.addHistoricalRecord(status: .failed)
                f.model.retry(id); try await until("historical transcription") { f.processing.entered }
                f.processing.release(); try await until("historical formatted completion") { f.model.phase == .done }
                try check(f.formatterRequests == 1 && f.model.activeRecord?.transcript == f.formattedText && f.insertions == 0,
                          "Formatting must preserve the historical retry insertion boundary")
            }),
            ("Provider defaults preserve legacy accounts without guessing credential contents", { f in
                try check(f.model.connectionProvider == .openAI, "Fresh users must default to direct OpenAI")
                let fixtures: [(CredentialSession.ReadResult, Bool, ConnectionProvider?, ConnectionProvider)] = [
                    (.value("local-test-team"), false, nil, .team),
                    (.blocked(errSecInteractionNotAllowed), false, nil, .team),
                    (.missing, true, nil, .team),
                    (.value("local-test-team"), true, .openAI, .openAI)
                ]
                for (legacy, consent, explicit, expected) in fixtures {
                    let other = try Fixture(legacyCredential: legacy, storedProvider: explicit, existingConsent: consent)
                    do {
                        try check(other.model.connectionProvider == expected, "Existing, blocked and explicitly selected providers must retain their route")
                        if case .blocked = legacy {
                            try check(other.model.tokenAccessRequired && !other.model.hasKey, "Blocked legacy Team account must offer Unlock without switching providers")
                        }
                        try check(other.preferences.string(forKey: "connectionProvider") == expected.rawValue, "Resolved provider must persist as ordinary preference")
                    } catch { await other.close(); throw error }
                    await other.close()
                }
            }),
            ("Direct validation and transcription use only the direct credential", { f in
                let saved = await f.model.saveAndVerifyKey("local-test-new-direct")
                try check(saved && f.model.keyStatus == .verified, "Direct model probe 200 must verify saved credential")
                let request = ProviderProbeProtocol.requests.first!
                try check(request.url?.absoluteString == "https://api.openai.com/v1/models/gpt-transcribe" && request.httpMethod == "GET" && request.httpBody == nil,
                          "Direct verification must be a no-generation model GET")
                try check(request.value(forHTTPHeaderField: "Authorization") == "Bearer local-test-new-direct", "Direct request must use its own account")
                try await f.beginProcessing(); f.processing.release()
                try await until("direct transcription completed") { f.model.phase == .done }
                try check(f.seenProvider == .openAI && f.seenConfig?.baseURL == Config.openAIBaseURL && f.seenConfig?.authValue == "Bearer local-test-new-direct",
                          "Final transcription must use selected direct endpoint and direct credential")
                try check(f.credentialVault.get(.team) == nil, "Saving a direct key must not create or modify Team credential")
            }),
            ("Team verification preserves its legacy probe and account", { f in
                f.model.setConnectionProvider(.team); ProviderProbeProtocol.reset(status: 403)
                let saved = await f.model.saveAndVerifyKey("local-test-new-team")
                try check(saved && f.model.keyStatus == .verified, "Authenticated legacy Team probe 403 must remain verified")
                let request = ProviderProbeProtocol.requests.first!
                try check(request.url?.host == Config.teamBaseURL.host && request.httpMethod == "POST" && (request.httpBody != nil || request.httpBodyStream != nil),
                          "Team validation must remain on its fixed proxy")
                try check(request.value(forHTTPHeaderField: "Authorization") == "Bearer local-test-new-team", "Team request must use only Team credential")
                f.model.setConnectionProvider(.openAI)
                try check(f.model.keyFingerprint == "rect" && f.credentialVault.get(.openAI) == "local-test-direct",
                          "Switching from Team must restore direct cached metadata without altering its key")
                f.model.setConnectionProvider(.team)
                try check(f.model.keyStatus == .verified && f.model.keyFingerprint == "team", "Provider status and fingerprint must remain scoped")
                try await f.beginProcessing(); f.processing.release()
                try await until("Team transcription completed") { f.model.phase == .done }
                try check(f.seenProvider == .team && f.seenConfig?.baseURL == Config.teamBaseURL && f.seenConfig?.authValue == "Bearer local-test-new-team",
                          "Team transcription must use only the Team endpoint and Team account")
            }),
            ("Direct verification distinguishes rejection from uncertain capability", { f in
                for (code, expected) in [(401, AppModel.KeyStatus.rejected), (403, .savedUnverified), (404, .savedUnverified), (429, .savedUnverified), (-1, .savedUnverified)] {
                    ProviderProbeProtocol.reset(status: code)
                    _ = await f.model.saveAndVerifyKey("local-test-direct")
                    try check(f.model.keyStatus == expected, "Only direct401 is known authentication rejection; unavailable model/permission remains unverified")
                }
            }),
            ("Connection commands block concurrent validation and capture", { f in
                ProviderProbeProtocol.reset(status: nil)
                let saving = Task { await f.model.saveAndVerifyKey("local-test-direct") }
                try await until("pending verification") { ProviderProbeProtocol.requests.count == 1 }
                f.model.setConnectionProvider(.team); f.model.unlockToken()
                let second = await f.model.saveAndVerifyKey("local-test-second")
                try check(!second && f.model.connectionProvider == .openAI && ProviderProbeProtocol.requests.count == 1,
                          "Checking must guard provider changes, unlock and duplicate saves in the model")
                ProviderProbeProtocol.finish(status: 200); _ = await saving.value
                try await f.beginRecording()
                f.model.setConnectionProvider(.team); f.model.unlockToken()
                let busySave = await f.model.saveAndVerifyKey("local-test-busy")
                try check(!busySave && f.model.connectionProvider == .openAI, "Capture must freeze endpoint/account selection and writes")
                f.model.cancelDictation(); try await until("provider guard capture stop") { f.model.phase == .done }
            }),
            ("Stale verification cannot update a different provider", { f in
                ProviderProbeProtocol.reset(status: nil)
                let saving = Task { await f.model.saveAndVerifyKey("local-test-direct") }
                try await until("pending stale verification") { ProviderProbeProtocol.requests.count == 1 }
                // Simulate a stale view resetting display status. Request-generation and
                // provider snapshot still protect the selected account after the await.
                f.model.keyStatus = .idle; f.model.setConnectionProvider(.team)
                ProviderProbeProtocol.finish(status: 200); _ = await saving.value
                try check(f.model.connectionProvider == .team && f.model.keyStatus == .idle && !f.model.hasKey,
                          "Late direct verification must not verify or populate the Team account")
            }),
            ("Missing locked and rejected selected credentials refuse capture with provider-specific guidance", { _ in
                let cases: [(ConnectionProvider, CredentialSession.ReadResult, String, Bool)] = [
                    (.team, .missing, "Add your team token in Settings.", false),
                    (.openAI, .missing, "Add your OpenAI API key in Settings.", false),
                    (.team, .blocked(errSecInteractionNotAllowed), "Unlock your team token in Settings.", true),
                    (.openAI, .blocked(errSecInteractionNotAllowed), "Unlock your OpenAI API key in Settings.", true)
                ]
                for (provider, credential, message, locked) in cases {
                    let f = try Fixture(legacyCredential: credential, storedProvider: provider, directCredential: credential)
                    var settings = 0; f.model.showSettings = { settings += 1 }
                    // An old hasKey snapshot must not bypass the actual selected account read.
                    f.model.hasKey = true; f.model.startDictation(); f.model.startMeeting()
                    try check(f.model.statusDetail == message && settings == 2 && f.starts == 0 && f.model.records.isEmpty &&
                              !f.model.hasKey && f.model.tokenAccessRequired == locked,
                              "Credential preflight identifies selected account before saving/capture")
                    await f.close()
                }
                let f = try Fixture(storedProvider: .team, directCredential: .missing)
                try f.credentialVault.set("local-rejected-team", for: .team)
                f.model.keyStatus = .rejected; f.model.startDictation()
                try check(f.model.statusDetail == "Your team token was rejected." && f.starts == 0 && f.model.records.isEmpty,
                          "Known rejection must not be relabeled as missing")
                await f.close()
            }),
            ("Saved-audio retry retains missing credential remedy and succeeds only after selected-account repair", { _ in
                let f = try Fixture(storedProvider: .team)
                let id = try f.addHistoricalRecord(status: .failed)
                let original = f.model.records.first { $0.id == id }!
                f.model.retry(id)
                let blocked = try f.store.load().first { $0.id == id }!
                try check(blocked.tracks == original.tracks && blocked.status == original.status && blocked.canRecover &&
                          blocked.transcriptionIssues.first?.failureKind == .credentialMissing && blocked.serviceProviderID == "team" &&
                          f.model.serviceNotice(for: blocked)?.message == "Add your team token in Settings." && f.transcriptionRequests == 0,
                          "Missing account never discards captured audio or implies dictionary failure")
                try f.credentialVault.set("local-repaired-team", for: .team)
                f.model.retry(id); try await until("credential repaired ASR retry") { f.processing.entered }
                f.processing.release(); try await until("credential repaired historical completion") { f.model.phase == .done }
                try check(f.transcriptionRequests == 1 && f.seenProvider == .team && f.insertions == 0 &&
                          f.model.records.first { $0.id == id }?.transcriptionIssues.isEmpty == true,
                          "Explicit saved-audio retry uses repaired selected credential without automatic paste")
                await f.close()
            }),
            ("Remote configuration failures never blame local dictionary hints", { f in
                var record = SessionRecord(kind: .meeting, title: "Configuration fixture")
                record.liveMeetingVersion = 1; record.serviceProviderID = "team"
                for category in [ServiceFailureKind.configuration, .invalidHints] {
                    record.transcriptionIssues = [.init(userMessage: "Safe fixture", failureKind: category)]
                    let notice = f.model.serviceNotice(for: record)
                    try check(notice?.message == "The transcription service could not accept this request." && notice?.action == .settings,
                              "Remote and historical live configuration failure uses neutral setup advice")
                }
                record.liveMeetingVersion = nil
                try check(f.model.serviceNotice(for: record)?.message == "Review your language and dictionary settings.",
                          "Actual local hint validation keeps its precise remedy")
            }),
            ("Checking or rejected tokens cannot begin capture", { f in
                f.model.keyStatus = .checking; f.model.startDictation()
                f.model.keyStatus = .rejected; f.model.startDictation()
                try check(f.model.records.isEmpty && f.starts == 0 && !f.model.ready,
                          "Unverified in-flight or known-rejected credentials must not capture audio")
                f.model.keyStatus = .idle; try await f.beginRecording()
                f.model.cancelDictation(); try await until("allowed recording cancellation") { f.model.phase == .done }
            }),
            ("Recording-status commit failure stops capture before processing", { f in
                f.recordingSaveFails = true; f.model.startDictation(); f.startup.release()
                try await until("recording commit failure") { f.model.phase == .error }
                try check(f.stops == 1 && f.transcriptionRequests == 0 && f.insertions == 0 && f.cleanups == 0,
                          "Failed startup metadata must stop once without upload, insertion or cleanup")
                let record = try f.store.load().first
                try check(f.audioExists() && record?.canRecover == true && record?.delivery == .ready,
                          "Stopped startup failure must retain durable recovery without insertion eligibility")
            }),
            ("Failed startup and stop commits recover from the capture manifest", { f in
                f.recordingSaveFails = true; f.stopSaveFails = true
                f.model.startDictation(); f.startup.release()
                try await until("both capture commits failed") { f.model.phase == .error }
                try check(f.stops == 1 && f.transcriptionRequests == 0 && f.insertions == 0 && f.cleanups == 0,
                          "Failure to commit stop must not upload or deliver")
                let record = try f.store.load().first
                try check(f.audioExists() && record?.canRecover == true && record?.delivery == .ready,
                          "The initial durable record plus raw manifest must recover after both later commits fail")
            }),
            ("Dictionary stays within the provider's 100-keyword limit", { f in
                for i in 0..<101 { f.model.addDictionaryWord("Term \(i)") }
                try check(f.model.dictionaryWords.count == 100, "The UI must not persist a 101st provider keyword")
                try check(!f.model.dictionaryWords.contains("Term 100"), "Excess hints must be explicitly refused, not truncated on upload")
                f.model.removeDictionaryWord("Term 0"); f.model.addDictionaryWord("Replacement")
                try check(f.model.dictionaryWords.count == 100 && f.model.dictionaryWords.contains("Replacement"),
                          "Removing a hint must free one provider slot")
            }),
            ("Escape during startup preserves audio and prevents processing", { f in
                f.model.startDictation()
                try await until("startup request") { f.startup.entered }
                f.model.cancelDictation()
                try check(f.model.phase == .stopping, "Escape must reserve the stopping phase immediately")
                try check(f.model.activeRecord?.delivery == .cancelled, "Cancellation must commit before startup finishes")
                f.startup.release()
                try await until("cancelled stop") { f.model.phase == .done }
                try check(f.stops == 1 && f.transcriptionRequests == 0 && f.insertions == 0 && f.cleanups == 0,
                          "Startup cancellation must stop once without processing, delivery or cleanup")
                try check(f.audioExists(), "Cancelled audio must remain on disk")
                let reloaded = try f.store.load().first
                try check(reloaded?.canRecover == true, "Cancelled speech must survive reload")
            }),
            ("Escape during processing prevents late insertion and cleanup", { f in
                f.automaticOutcome = .ready(reason: "Capture unavailable")
                try await f.beginProcessing(); f.model.cancelDictation(); f.processing.release()
                try await until("cancelled processing") { f.model.phase == .done }
                try check(f.model.activeRecord?.transcript == "Saved speech", "Late final text must remain recoverable")
                try check(f.model.activeRecord?.delivery == .cancelled && f.insertions == 0 && f.cleanups == 0,
                          "A late processing result cannot deliver or clean up cancelled speech")
                try check(f.audioExists(), "Processing cancellation must retain audio")
                try check(f.model.activeRecord?.issues.isEmpty == true,
                          "A cancelled delivery must not acquire delivery diagnostics")
            }),
            ("Second toggle during startup and repeated finish stop exactly once", { f in
                f.model.toggleDictation()
                try await until("startup request") { f.startup.entered }
                f.model.toggleDictation(); f.model.finishRecording(); f.model.toggleDictation()
                try check(f.model.phase == .stopping && f.model.records.count == 1, "Second toggle must finish pending startup")
                f.startup.release()
                try await until("processing request") { f.processing.entered }
                f.model.finishRecording(); f.processing.release()
                try await until("completed processing") { f.model.phase == .done }
                try check(f.starts == 1 && f.stops == 1 && f.transcriptionRequests == 1, "Finish must remain idempotent")
                try check(f.insertions == 1 && f.insertedAfterDurableText, "Automatic insertion must follow durable final text")
                try check(f.cleanups == 1 && !f.audioExists(), "Successful owned audio cleanup must occur after delivery")
            }),
            ("Automatic paste targets focus at final completion", { f in
                try await f.beginProcessing()
                try check(f.insertions == 0, "Recording and processing must not capture or paste into a destination")
                f.currentFocus = "Field B"; f.processing.release()
                try await until("current focus completion") { f.model.phase == .done }
                try check(f.deliveryWrites == 1 && f.deliveredFocus == "Field B" && f.insertedAfterDurableText,
                          "Final durable text must paste once at the current completion-time caret")
            }),
            ("Escape while delivery waits prevents its final write", { f in
                f.blocksDelivery = true
                try await f.beginProcessing(); f.processing.release()
                try await until("pending delivery") { f.delivery.entered }
                try check(f.model.phase == .transcribing && f.insertedAfterDurableText,
                          "Final text must already be durable while asynchronous delivery stays busy")
                f.model.cancelDictation(); f.delivery.release()
                try await until("cancelled delivery completion") { f.model.phase == .done }
                let saved = try f.store.load().first
                try check(f.deliveryWrites == 0 && f.copies == 0 && f.cleanups == 0 && f.audioExists(),
                          "The final delivery guard must prevent writes and preserve cancelled audio")
                try check(saved?.transcript == "Saved speech" && saved?.delivery == .cancelled && saved?.issues.isEmpty == true,
                          "Late cancellation must preserve final text without delivery failure diagnostics")
            }),
            ("Manual delivery latch blocks duplicate paste and new capture", { f in
                _ = try f.addHistoricalRecord(); f.blocksDelivery = true
                f.model.pasteLast()
                try await until("pending manual delivery") { f.delivery.entered }
                f.model.pasteLast(); f.model.startDictation(); f.model.startMeeting()
                f.model.setConnectionProvider(.team); f.model.unlockToken()
                let busySave = await f.model.saveAndVerifyKey("local-test-busy-manual")
                try check(f.manualPastes == 1 && f.starts == 0 && f.model.records.count == 1,
                          "A pending manual paste must serialize clipboard ownership and prevent new capture")
                try check(!busySave && f.model.connectionProvider == .openAI && ProviderProbeProtocol.requests.isEmpty,
                          "Pending clipboard delivery must also block provider changes, unlock and key saves")
                f.delivery.release()
                try await until("manual delivery finished") { f.deliveryCompletions == 1 && f.model.chipState == .inserted }
                try check(f.deliveryWrites == 1 && f.copies == 0, "Manual delivery must dispatch exactly once")
            }),
            ("Monotonic 4:30 warning and five-minute hard stop", { f in
                try await f.beginRecording()
                f.now = 10_269.9; f.model.updateRecordingTime()
                try check(f.model.chipState == .recording && f.model.phase == .recording, "Recording must continue before warning")
                f.now = 10_270; f.model.updateRecordingTime()
                try check(f.model.chipState == .warning && f.model.chipVisible, "4:30 warning must be visible")
                f.now = 10_300; f.model.updateRecordingTime(); f.model.updateRecordingTime()
                try check(f.model.phase == .stopping, "Five-minute deadline must stop synchronously")
                try await until("processing request") { f.processing.entered }
                f.processing.release(); try await until("completed deadline") { f.model.phase == .done }
                try check(f.stops == 1 && f.model.activeRecord?.duration == 300, "Deadline stop must run once with monotonic duration")
            }),
            ("Final persistence failure prevents insertion and actual deletion", { f in
                f.automaticOutcome = .ready(reason: "Capture unavailable")
                try await f.beginProcessing(); f.finalSaveFails = true; f.processing.release()
                try await until("save error") { f.model.phase == .error }
                try check(f.insertions == 0 && f.cleanups == 0 && f.audioExists(), "Failed final save must block insertion and deletion")
                let saved = try f.store.load().first
                try check(saved?.transcript.isEmpty == true && saved?.canRecover == true,
                          "Reload must recover audio without pretending failed final text was saved")
                try check(f.model.activeRecord?.issues.isEmpty == true,
                          "Delivery diagnostics cannot be committed before final text")
            }),
            ("Historical retry never automatically inserts", { f in
                f.automaticOutcome = .ready(reason: "Capture unavailable")
                let id = try f.addHistoricalRecord(status: .failed)
                f.model.retry(id)
                try await until("historical processing") { f.processing.entered }
                f.processing.release(); try await until("historical completion") { f.model.phase == .done }
                try check(f.starts == 0 && f.insertions == 0 && f.model.activeRecord?.delivery == .ready,
                          "Retry must save Ready text without capture or automatic insertion")
                try check(f.model.activeRecord?.issues.isEmpty == true,
                          "Historical processing must not report a new delivery attempt")
            }),
            ("Unavailable automatic destination retains its reason after durable text", { f in
                let reason = "Enable Accessibility to insert text."
                f.automaticOutcome = .ready(reason: reason)
                try await f.beginProcessing(); f.processing.release()
                try await until("unavailable destination completion") { f.model.phase == .done }
                let saved = try f.store.load().first
                try check(f.insertions == 1 && f.insertedAfterDurableText && f.copies == 0,
                          "Captured delivery failure must resolve once after durable text without copying")
                try check(saved?.status == .complete && saved?.delivery == .ready && saved?.issues == [reason],
                          "Capture failure reason must survive reload without claiming insertion")
                try check(saved?.transcriptionIssues.isEmpty == true && saved?.isPartial == false &&
                          f.model.deliveryDetail == reason && f.model.statusDetail.isEmpty && f.model.chipState == .ready,
                          "Delivery diagnostics must not create partial transcription or retry eligibility")
            }),
            ("Unconfirmed automatic write remains saved without claiming insertion", { f in
                let reason = "Insertion unconfirmed. Check the original field before pasting again."
                f.automaticOutcome = .unconfirmed(reason: reason)
                try await f.beginProcessing(); f.processing.release()
                try await until("unconfirmed automatic completion") { f.model.phase == .done }
                let saved = try f.store.load().first
                try check(f.insertions == 1 && f.insertedAfterDurableText && f.copies == 0,
                          "An unconfirmed write must not automatically copy or retry")
                try check(saved?.transcript == "Saved speech" && saved?.delivery == .ready &&
                          saved?.issues == [reason] && f.model.deliveryDetail == reason && f.model.statusDetail.isEmpty,
                          "Uncertainty must remain visible beside durable text without claiming verified insertion")
            }),
            ("Unavailable manual paste preserves clipboard and saves its reason", { f in
                let reason = "Select an editable field."
                let id = try f.addHistoricalRecord(); f.manualOutcome = .ready(reason: reason)
                try await f.pasteLast()
                let saved = try f.store.load().first { $0.id == id }
                try check(f.manualPastes == 1 && f.copies == 0 && f.insertions == 0,
                          "A manual command with no write must leave the existing clipboard untouched")
                try check(saved?.issues == [reason] && f.model.deliveryDetail == reason && f.model.statusDetail.isEmpty,
                          "Manual delivery diagnostics must survive reload")
                try await f.pasteLast()
                let repeated = try f.store.load().first { $0.id == id }
                try check(f.copies == 0 && repeated?.issues == [reason],
                          "Repeated unavailable paste must preserve clipboard without duplicating its saved warning")
                f.manualOutcome = .inserted; try await f.pasteLast()
                let successful = try f.store.load().first { $0.id == id }
                try check(f.model.deliveryDetail.isEmpty && f.model.statusDetail.isEmpty && f.model.chipState == .inserted &&
                          f.copies == 0 && successful?.issues == [reason],
                          "Confirmed manual insertion must clear stale current feedback while retaining history")
            }),
            ("Unconfirmed manual write never copies or changes cancellation recovery", { f in
                let reason = "Insertion unconfirmed. Check the original field before pasting again."
                let id = try f.addHistoricalRecord(); f.manualOutcome = .unconfirmed(reason: reason)
                try await f.pasteLast()
                let saved = try f.store.load().first { $0.id == id }
                try check(f.manualPastes == 1 && f.copies == 0 && saved?.issues == [reason],
                          "Uncertain manual writes must leave the clipboard untouched and save their warning")
                var cancelled = f.model.records[0]
                cancelled.status = .cancelled; cancelled.delivery = .cancelled; cancelled.issues = []
                try f.store.save(cancelled); f.model.records[0] = cancelled
                try await f.pasteLast()
                let after = try f.store.load().first { $0.id == id }
                try check(f.copies == 0 && after?.issues.isEmpty == true && after?.delivery == .cancelled,
                          "An explicit manual command must not contaminate cancelled-transcript recovery state")
                f.model.retry(id)
                try check(f.model.activeRecord?.status == .complete && f.model.activeRecord?.delivery == .ready &&
                          f.transcriptionRequests == 0 && f.insertions == 0,
                          "Cancelled final text must still recover without upload or automatic insertion")
            }),
            ("Updater quit preserves completed dictation history", { f in
                try await f.beginProcessing(); f.processing.release()
                try await until("completed dictation before updater") { f.model.phase == .done }
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                let before = try encoder.encode(f.store.load()[0])
                try check(f.model.acquireUpdateLock(), "Idle completed dictation allows update")
                f.model.cancelDictation()
                await f.model.prepareToQuit()
                let after = try encoder.encode(f.store.load()[0])
                try check(after == before,
                          "Updater latch must not cancel or mutate last completed dictation")
            }),
            ("Live meeting saves permanent passages and recovers only missing without legacy ASR or delivery", { _ in
                let f = try Fixture(liveMeetingEnabled: true)
                f.model.meetingMode = .inPerson; f.model.startMeeting(); f.startup.release()
                try await until("live meeting recording") { f.model.phase == .recording }
                guard let persist = f.livePersist else { throw CheckFailure(description: "Missing live persistence hook") }
                f.liveIssue?(TranscriptionIssue(source: .system, userMessage: "Safe fixture billing", failureKind: .billingLimit))
                try await until("source notice received") { f.model.activeRecord?.transcriptionIssues.contains { $0.failureKind == .billingLimit } == true }
                let turn = MeetingTurn(idx: 0, source: .mic, start: 0, end: 1, state: .confirmed, text: "Permanent live words")
                try await persist([turn])
                try check(f.model.activeRecord?.transcript.contains("Permanent live words") == true &&
                          f.model.activeRecord?.transcriptionIssues.contains { $0.failureKind == .billingLimit } == true,
                          "Confirmed passage is durable and another source account issue is retained")
                try check(!f.model.canBeginUpdate, "Owned live controller blocks updater")
                f.model.finishRecording()
                try await until("live meeting finalized") { f.model.phase == .done }
                let saved = try f.store.load()[0]
                try check(saved.status == .complete && saved.meetingTurns[0] == turn && saved.meetingTurns.count == 2 &&
                          saved.transcriptionIssues.isEmpty && f.liveRecoveries == 1 && f.recoveredInput == [turn],
                          "Recovery appends only unfinished audio and clears remedied source notices")
                try check(f.transcriptionRequests == 0 && f.formatterRequests == 0 && f.insertions == 0 && f.manualPastes == 0,
                          "Live meetings never use final rewrite, formatter or paste")
                let revision = saved.transcriptRevision
                f.model.retry(saved.id)
                try check(f.model.activeRecord?.transcriptRevision == revision, "Completed live retry never rewrites confirmed words")
                await f.close()
            }),
            ("Live completed transcript survives audio cleanup failure without retry", { _ in
                let f = try Fixture(liveMeetingEnabled: true)
                f.cleanupFails = true
                f.model.meetingMode = .inPerson; f.model.startMeeting(); f.startup.release()
                try await until("live cleanup fixture recording") { f.model.phase == .recording }
                f.model.finishRecording()
                try await until("live cleanup failure completed") { f.model.phase == .done }
                let saved = try f.store.load()[0]
                try check(f.cleanups == 1 && f.audioExists() && saved.status == .complete && saved.hasSealedMeetingAudio && saved.hasText,
                          "Cleanup failure retains raw audio and complete durable text")
                try check(!saved.canRecover && saved.transcriptionIssues.isEmpty && f.model.serviceNotice(for: saved) == nil &&
                          saved.issues.isEmpty && f.model.statusDetail.isEmpty,
                          "Audio retention produces no nonactionable warning, false processing error or Retry")
                await f.close()
            }),
            ("Live passage save failure remains invisible and stale session callbacks cannot mutate history", { _ in
                let f = try Fixture(liveMeetingEnabled: true)
                f.model.meetingMode = .inPerson; f.model.startMeeting(); f.startup.release()
                try await until("live failed-save recording") { f.model.phase == .recording }
                guard let persist = f.livePersist else { throw CheckFailure(description: "Missing live hook") }
                f.liveConfirmedSaveFails = true
                do {
                    try await persist([MeetingTurn(idx: 0, source: .mic, start: 0, end: 1, state: .confirmed, text: "Unsaved")])
                    throw CheckFailure(description: "Failed passage save unexpectedly succeeded")
                } catch let failure as CheckFailure { throw failure } catch {}
                try check(f.model.activeRecord?.hasText == false && f.model.activeRecord?.meetingTurns.isEmpty == true,
                          "Persistence failure cannot publish provisional words as permanent")
                f.liveConfirmedSaveFails = false
                await f.model.prepareToQuit()
                do {
                    try await persist([MeetingTurn(idx: 0, source: .mic, start: 0, end: 1, state: .confirmed, text: "Stale")])
                    throw CheckFailure(description: "Stale live callback unexpectedly succeeded")
                } catch let failure as CheckFailure { throw failure } catch {}
                try check(f.model.records[0].hasText == false && f.insertions == 0, "Late cancelled generation cannot write history")
                await f.close()
            }),
            ("Paste-last while recording preserves indicator and warning", { f in
                _ = try f.addHistoricalRecord(); try await f.beginRecording()
                f.levelCallback?(.mic, 0.6)
                try await until("actual level callback") { f.model.micLevel == 0.6 }
                f.model.pasteLast()
                try check(f.model.chipState == .recording && f.model.chipVisible && f.manualPastes == 0 && f.copies == 0,
                          "Busy paste-last must leave active capture feedback and destination untouched")
                f.now += 270; f.model.updateRecordingTime()
                try check(f.model.chipState == .warning && f.model.chipVisible, "Paste-last cannot suppress the warning")
                f.model.cancelDictation(); try await until("cancelled recording") { f.model.phase == .done }
            })
        ]
        var failures = 0
        for (name, body) in cases {
            var fixture: Fixture?
            do {
                let f = try Fixture(); fixture = f; try await body(f)
                print("PASS " + name)
            } catch { failures += 1; print("FAIL \(name): \(error)") }
            await fixture?.close()
        }
        if failures > 0 { exit(1) }
        print("coordinator selftest: all actual AppModel lifecycle checks passed")
    }
}
