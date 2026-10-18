import Foundation

private final class SessionStoreChecks {
    var failures: [String] = []
    func XCTAssertTrue(_ condition: Bool, _ message: String = "", file: StaticString = #fileID, line: UInt = #line) { if !condition { failures.append("Assertion failed at \(file):\(line) \(message)") } }
    func XCTAssertFalse(_ condition: Bool, _ message: String = "", file: StaticString = #fileID, line: UInt = #line) { XCTAssertTrue(!condition, message, file: file, line: line) }
    func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "", file: StaticString = #fileID, line: UInt = #line) { XCTAssertTrue(a == b, message, file: file, line: line) }
    func XCTUnwrap<T>(_ value: T?) throws -> T { guard let value else { throw CocoaError(.fileReadCorruptFile) }; return value }
    private var directory: URL!
    private var store: SessionStore!
    func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = try SessionStore(root: directory)
    }
    func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func testAtomicRecordAndInterruptedProcessingDisableInsertion() throws {
        var record = SessionRecord(kind: .dictation, title: "Draft")
        record.status = .processing; record.transcript = "Accepted chunk"
        try store.save(record)
        let loaded = try XCTUnwrap(store.load().first)
        XCTAssertEqual(loaded.id, record.id)
        XCTAssertEqual(loaded.transcript, "Accepted chunk")
        XCTAssertEqual(loaded.status, .failed)
        XCTAssertEqual(loaded.delivery, .ready)
        XCTAssertFalse(loaded.captureIncomplete, "Processing interruption is not an audio gap")
        let attrs = try FileManager.default.attributesOfItem(atPath: store.directory(for: record.id).appendingPathComponent("record.json").path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testCancelledDeliverySurvivesRestart() throws {
        var record = SessionRecord(kind: .dictation, title: "Cancelled")
        record.status = .cancelled; record.delivery = .cancelled
        try store.save(record)
        XCTAssertEqual(try store.load().first?.delivery, .cancelled)
    }
    func testInterruptedLiveDictationRecoversTailWithoutRewritingConfirmedText() throws {
        var record = SessionRecord(kind: .dictation, title: "Interrupted dictation")
        record.liveDictationVersion = 1; record.status = .recording
        let dir = store.directory(for: record.id)
        record.tracks = [.init(source: .mic, spans: [.init(url: dir.appendingPathComponent("mic.wav"), offset: 0, duration: 1)])]
        try record.applyMeetingTurns([.init(idx: 0, source: .mic, start: 0, end: 1, state: .confirmed, text: "Already saved")])
        try store.save(record)
        let tail = SessionAudioTrack(source: .mic, spans: [.init(url: dir.appendingPathComponent("mic.wav"), offset: 0, duration: 2)])
        try JSONEncoder().encode(tail).write(to: dir.appendingPathComponent("mic-capture.json"))
        let restored = try XCTUnwrap(store.load().first)
        XCTAssertEqual(restored.transcript, "Already saved")
        XCTAssertEqual(restored.rawTranscript, "Already saved")
        XCTAssertEqual(restored.tracks, [tail])
        XCTAssertEqual(restored.meetingTurns, record.meetingTurns)
        XCTAssertTrue(restored.canRecover)
        XCTAssertEqual(restored.status, .failed)
        XCTAssertEqual(restored.delivery, .ready)
    }
    func testCancelledCaptureManifestRecoversBeforeStopCommit() throws {
        var record = SessionRecord(kind: .dictation, title: "Interrupted cancel")
        record.status = .cancelled; record.delivery = .cancelled; try store.save(record)
        let dir = store.directory(for: record.id)
        let track = SessionAudioTrack(source: .mic, spans: [AudioSpan(url: dir.appendingPathComponent("mic_part_00000.wav"), offset: 0.2, duration: 2)])
        try JSONEncoder().encode(track).write(to: dir.appendingPathComponent("mic-capture.json"))
        let recovered = try XCTUnwrap(store.load().first)
        XCTAssertTrue(recovered.canRecover)
        XCTAssertEqual(recovered.tracks, [track])
        XCTAssertEqual(recovered.delivery, .cancelled)
        XCTAssertTrue(recovered.captureIncomplete)
    }
    func testCaptureGapWithoutMissingTranscriptionDoesNotOfferFutileRetry() throws {
        var record = SessionRecord(kind: .meeting, title: "Gap")
        record.status = .partial; record.captureIncomplete = true
        record.tracks = [SessionAudioTrack(source: .mic, spans: [AudioSpan(url: directory.appendingPathComponent("mic.wav"), offset: 0, duration: 1)])]
        XCTAssertFalse(record.canRecover)
        record.transcriptionIssues = [TranscriptionIssue(userMessage: "Retry section", retryable: true)]
        XCTAssertTrue(record.canRecover)
    }
    func testDamagedRecordDoesNotHideValidHistory() throws {
        var record = SessionRecord(kind: .meeting, title: "Meeting"); record.status = .complete
        try store.save(record)
        let bad = directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: bad.appendingPathComponent("record.json"))
        XCTAssertEqual(try store.load().map(\.id), [record.id])
        XCTAssertEqual(store.loadIssues.count, 1)
    }
    func testCleanupRetainsPartialAndOnlyDeletesOwnedCompleteAudio() throws {
        var record = SessionRecord(kind: .meeting, title: "Partial"); record.status = .partial
        try store.save(record)
        let owned = store.directory(for: record.id).appendingPathComponent("mic.wav")
        let unrelated = directory.appendingPathComponent("unknown.wav")
        try Data([1]).write(to: owned); try Data([2]).write(to: unrelated)
        record.tracks = [SessionAudioTrack(source: .mic, spans: [AudioSpan(url: owned, offset: 0, duration: 1), AudioSpan(url: unrelated, offset: 1, duration: 1)])]
        try store.cleanAudio(for: record)
        XCTAssertTrue(FileManager.default.fileExists(atPath: owned.path))
        record.status = .complete; record.transcript = "Saved"; try store.save(record)
        try store.cleanAudio(for: record)
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }
    func testExpiryPreservesFailuresAndUnmanagedAudio() throws {
        let now = Date(), store = self.store!
        var records: [SessionRecord] = []
        for status: SessionStatus in [.complete, .failed, .partial, .cancelled] {
            var record = SessionRecord(kind: .dictation, title: "Retention fixture")
            record.status = status; record.transcript = "Saved text"; record.audioCompletedAt = now.addingTimeInterval(-8 * 86_400)
            try store.save(record)
            let file = store.directory(for: record.id).appendingPathComponent("mic.wav")
            try Data([1]).write(to: file)
            record.tracks = [.init(source: .mic, spans: [.init(url: file, offset: 0, duration: 1)])]
            records.append(record)
        }
        var recent = SessionRecord(kind: .dictation, title: "Recent")
        recent.status = .complete; recent.transcript = "Saved"; recent.audioCompletedAt = now
        try store.save(recent)
        let file = store.directory(for: recent.id).appendingPathComponent("mic.wav")
        try Data([1]).write(to: file); recent.tracks = [.init(source: .mic, spans: [.init(url: file, offset: 0, duration: 1)])]
        records.append(recent)
        try store.purgeExpiredAudio(records: records, days: 7, now: now)
        for record in records {
            XCTAssertEqual(FileManager.default.fileExists(atPath: record.tracks[0].spans[0].url.path), record.id != records[0].id)
        }
        var legacy = recent; legacy.audioCompletedAt = nil
        try store.purgeExpiredAudio(records: [legacy], days: 7, now: now.addingTimeInterval(100 * 86_400))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "no expiry for old unmanaged audio")
    }
    func testLegacyMarkdownImportedOnceWithoutChangingOriginal() throws {
        let folder = directory.appendingPathComponent("exports")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = folder.appendingPathComponent("Old meeting.md")
        try "Original notes".write(to: original, atomically: true, encoding: .utf8)
        let imported = try store.importMarkdown(from: folder, existing: [])
        XCTAssertEqual(imported.count, 1); XCTAssertTrue(imported[0].imported)
        XCTAssertTrue(try store.importMarkdown(from: folder, existing: imported).isEmpty)
        var exported = imported[0]
        let exportedURL = folder.appendingPathComponent("New export.md")
        try "New export".write(to: exportedURL, atomically: true, encoding: .utf8)
        exported.exportURL = exportedURL
        XCTAssertTrue(try store.importMarkdown(from: folder, existing: [exported]).isEmpty,
                      "Exporting must not lose the original import identity")
        XCTAssertEqual(try String(contentsOf: original), "Original notes")
    }
}


public func runSessionStoreSelftests() -> Bool {
    let checks = SessionStoreChecks()
    let tests: [(String, () throws -> Void)] = [
        ("durable processing recovery", checks.testAtomicRecordAndInterruptedProcessingDisableInsertion),
        ("cancelled delivery persists", checks.testCancelledDeliverySurvivesRestart),
        ("interrupted live dictation tail recovery", checks.testInterruptedLiveDictationRecoversTailWithoutRewritingConfirmedText),
        ("cancelled capture manifest recovery", checks.testCancelledCaptureManifestRecoversBeforeStopCommit),
        ("capture gap retry policy", checks.testCaptureGapWithoutMissingTranscriptionDoesNotOfferFutileRetry),
        ("corrupt record isolation", checks.testDamagedRecordDoesNotHideValidHistory),
        ("owned complete audio cleanup", checks.testCleanupRetainsPartialAndOnlyDeletesOwnedCompleteAudio),
        ("audio expiry preserves incomplete recordings", checks.testExpiryPreservesFailuresAndUnmanagedAudio),
        ("read-only legacy import", checks.testLegacyMarkdownImportedOnceWithoutChangingOriginal)]
    for (name, test) in tests {
        let before = checks.failures.count
        do { try checks.setUpWithError(); try test() }
        catch { checks.failures.append("Failed: \(name)") }
        try? checks.tearDownWithError()
        print("\(checks.failures.count == before ? "PASS" : "FAIL") \(name)")
    }
    for failure in checks.failures { print(failure) }
    return checks.failures.isEmpty
}
