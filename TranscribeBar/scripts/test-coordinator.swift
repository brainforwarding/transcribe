import Foundation
import TranscribeCore

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
    let startup = Gate()
    let processing = Gate()
    var model: AppModel!
    var now = 10_000.0
    var starts = 0
    var stops = 0
    var transcriptionRequests = 0
    var insertions = 0
    var manualPastes = 0
    var copies = 0
    var cleanups = 0
    var finalSaveFails = false
    var recordingSaveFails = false
    var stopSaveFails = false
    var artifact: URL?
    var insertedAfterDurableText = false
    var automaticOutcome: PasteService.Outcome = .inserted
    var manualOutcome: PasteService.Outcome = .inserted
    var levelCallback: (@Sendable (Source, Double) -> Void)?

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("transcribe-coordinator-" + UUID().uuidString)
        store = try SessionStore(root: folder.appendingPathComponent("sessions"))
        preferences = UserDefaults(suiteName: preferenceDomain)!
        preferences.set(true, forKey: "consentAccepted")
        preferences.set(false, forKey: "keepAudio")
        preferences.set(false, forKey: "includeSummary")
        preferences.set(folder.appendingPathComponent("exports").path, forKey: "saveFolderPath")
        let operations = AppModel.Operations(makeCapture: { [self] directory, _, _, level, _, _ in
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
        }, transcribe: { [self] _, _, _ in
            transcriptionRequests += 1; await processing.wait()
            return FinalTranscription(text: "Saved speech", segments: [], complete: true, issues: [])
        }, uptime: { [self] in now }, credentials: {
            OpenAIConfig(baseURL: URL(string: "https://example.invalid/v1")!, authValue: "Bearer local-test-fixture")
        }, save: { [self] store, record in
            if recordingSaveFails && record.status == .recording { throw CocoaError(.fileWriteOutOfSpace) }
            if stopSaveFails && !record.tracks.isEmpty && !record.hasText { throw CocoaError(.fileWriteOutOfSpace) }
            if finalSaveFails && record.status == .complete && record.hasText { throw CocoaError(.fileWriteOutOfSpace) }
            try store.save(record)
        }, cleanAudio: { [self] store, record in
            cleanups += 1; try store.cleanAudio(for: record)
        }, captureInsertion: { [self] in
            return { [self] text in
                insertions += 1
                insertedAfterDurableText = (try? store.load().first?.transcript) == text
                return automaticOutcome
            }
        }, pasteAtCurrentCaret: { [self] _ in manualPastes += 1; return manualOutcome },
        copy: { [self] _ in copies += 1 }, automaticTimer: false)
        model = AppModel(store: store, operations: operations, preferences: preferences, initializeSystemState: false)
        model.micGranted = true; model.hasKey = true
    }
    func close() async {
        startup.release(); processing.release()
        await model?.prepareToQuit()
        model = nil
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
    func audioExists() -> Bool { artifact.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
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
                          f.model.statusDetail == reason && f.model.chipState == .ready,
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
                          saved?.issues == [reason] && f.model.statusDetail == reason,
                          "Uncertainty must remain visible beside durable text without claiming verified insertion")
            }),
            ("Definitively ready manual paste copies once and saves its reason", { f in
                let reason = "Select an editable field."
                let id = try f.addHistoricalRecord(); f.manualOutcome = .ready(reason: reason)
                f.model.pasteLast()
                let saved = try f.store.load().first { $0.id == id }
                try check(f.manualPastes == 1 && f.copies == 1 && f.insertions == 0,
                          "A manual command with no write may prepare exactly one explicit copy")
                try check(saved?.issues == [reason] && f.model.statusDetail == reason,
                          "Manual delivery diagnostics must survive reload")
                f.model.pasteLast()
                let repeated = try f.store.load().first { $0.id == id }
                try check(f.copies == 2 && repeated?.issues == [reason],
                          "Each explicit command may copy once without duplicating its saved warning")
                f.manualOutcome = .inserted; f.model.pasteLast()
                let successful = try f.store.load().first { $0.id == id }
                try check(f.model.statusDetail.isEmpty && f.model.chipState == .inserted &&
                          f.copies == 2 && successful?.issues == [reason],
                          "Confirmed manual insertion must clear stale current feedback while retaining history")
            }),
            ("Unconfirmed manual write never copies or changes cancellation recovery", { f in
                let reason = "Insertion unconfirmed. Check the original field before pasting again."
                let id = try f.addHistoricalRecord(); f.manualOutcome = .unconfirmed(reason: reason)
                f.model.pasteLast()
                let saved = try f.store.load().first { $0.id == id }
                try check(f.manualPastes == 1 && f.copies == 0 && saved?.issues == [reason],
                          "Uncertain manual writes must leave the clipboard untouched and save their warning")
                var cancelled = f.model.records[0]
                cancelled.status = .cancelled; cancelled.delivery = .cancelled; cancelled.issues = []
                try f.store.save(cancelled); f.model.records[0] = cancelled
                f.model.pasteLast()
                let after = try f.store.load().first { $0.id == id }
                try check(f.copies == 0 && after?.issues.isEmpty == true && after?.delivery == .cancelled,
                          "An explicit manual command must not contaminate cancelled-transcript recovery state")
                f.model.retry(id)
                try check(f.model.activeRecord?.status == .complete && f.model.activeRecord?.delivery == .ready &&
                          f.transcriptionRequests == 0 && f.insertions == 0,
                          "Cancelled final text must still recover without upload or automatic insertion")
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
