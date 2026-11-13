import Foundation

/// Formatter checks: speaker names from the source, merged paragraphs, plain copy text.
public func meetingTextSelftest() -> [String] {
    var failures: [String] = []
    func expect(_ condition: Bool, _ name: String) { print((condition ? "PASS " : "FAIL ") + "meeting text: " + name); if !condition { failures.append(name) } }
    func segment(_ start: Double, _ end: Double, _ source: Source, _ label: String, _ text: String, _ idx: Int) -> Segment {
        Segment(start: start, end: end, label: label, text: text, source: source, idx: idx)
    }
    var record = SessionRecord(kind: .meeting, title: "Meeting")
    record.segments = [segment(0, 2, .mic, "Microphone", "Hello there.", 0), segment(2.5, 4, .mic, "Microphone", "Second part.", 1),
                       segment(10, 12, .mic, "Microphone", "After a pause.", 2)]
    record.transcript = renderConversation(record.segments)
    expect(record.transcriptParagraphs.map(\.text) == ["Hello there. Second part.", "After a pause."]
           && record.transcriptParagraphs.allSatisfy { $0.speaker == nil }, "one source has paragraphs and no names")
    expect(record.copyableTranscript == "Hello there. Second part.\n\nAfter a pause.", "one source copies plain paragraphs")
    record.segments = [segment(0, 2, .mic, "You", "Can we start?", 0), segment(2.2, 4, .system, "System audio", "Yes, go ahead.", 1_000_000_000),
                       segment(4.1, 5, .mic, "You", "Thanks.", 1)]
    expect(record.transcriptParagraphs.map { $0.speaker ?? "" } == ["You", "Others", "You"], "old System audio labels read Others")
    expect(record.copyableTranscript == "You: Can we start?\n\nOthers: Yes, go ahead.\n\nYou: Thanks.", "two sources copy with names, no Markdown")
    expect(record.transcriptParagraphs.first?.start == 0 && record.transcriptParagraphs.last?.start == 4.1, "paragraphs keep their start time")
    record.segments = []; record.transcript = "# Imported\n\nSome **text**."
    expect(record.copyableTranscript == record.transcript && record.transcriptParagraphs.map(\.text) == ["# Imported\n\nSome **text**."],
           "records without segments are shown and copied unchanged")
    let long = String(repeating: "a", count: 200_000) + String(repeating: "b", count: 200_000)
    let source = overviewSource(long)
    expect(source.hasPrefix(String(repeating: "a", count: 150_000)) && source.hasSuffix(String(repeating: "b", count: 150_000))
           && source.count < 300_100, "long transcripts send their first and last 150,000 characters")
    expect(wordCount("one two\nthree  four") == 4, "word count")
    var legacy = Data(#"{"id":"\#(UUID().uuidString)","kind":"meeting","title":"Meeting","startedAt":0,"summary":"Old notes"}"#.utf8)
    expect((try? JSONDecoder().decode(SessionRecord.self, from: legacy)).map { $0.titleIsAutomatic && $0.overview.isEmpty && $0.summary == "Old notes" } == true,
           "legacy records decode with an automatic default title and their notes")
    legacy = Data(#"{"id":"\#(UUID().uuidString)","kind":"meeting","title":"Board","startedAt":0}"#.utf8)
    expect((try? JSONDecoder().decode(SessionRecord.self, from: legacy))?.titleIsAutomatic == false, "a named legacy record keeps its title")
    legacy = Data(#"{"id":"\#(UUID().uuidString)","kind":"meeting","title":"Board","startedAt":0,"language":"es"}"#.utf8)
    expect((try? JSONDecoder().decode(SessionRecord.self, from: legacy))?.languages == ["es"], "a single legacy language becomes one hint")
    let hinted = SessionRecord(kind: .meeting, title: "Board", languages: ["en", "es"])
    expect((try? JSONDecoder().decode(SessionRecord.self, from: JSONEncoder().encode(hinted)))?.languages == ["en", "es"], "language hints round-trip")
    var row = SessionRecord(kind: .meeting, title: "Row")
    row.status = .processing
    expect(row.listLine(transcribing: true) == "Transcribing…", "list: transcribing first")
    row.status = .failed
    expect(row.listLine(transcribing: false) == "Not transcribed", "list: not transcribed")
    row.status = .complete
    expect(row.listLine(transcribing: false) == "No speech", "list: no speech")
    row.segments = [segment(0, 1, .mic, "You", "First words.", 0)]; row.transcript = "x"
    expect(row.listLine(transcribing: false) == "First words.", "list: transcript start")
    row.overview = "The paragraph."
    expect(row.listLine(transcribing: false) == "The paragraph." && row.listLine(transcribing: true) == "Transcribing…", "list: summary")
    failures += trashSelftest()
    return failures
}

/// Move to a stand-in Trash and back; the real Trash is never touched.
func trashSelftest() -> [String] {
    var failures: [String] = []
    func expect(_ condition: Bool, _ name: String) { print((condition ? "PASS " : "FAIL ") + "trash: " + name); if !condition { failures.append(name) } }
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("transcribe-trash-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: base) }
    guard let store = try? SessionStore(root: base.appendingPathComponent("Sessions")) else { expect(false, "store"); return failures }
    let bin = base.appendingPathComponent("Bin", isDirectory: true)
    try? fm.createDirectory(at: bin, withIntermediateDirectories: true)
    let trash: (URL) throws -> URL = { url in let target = bin.appendingPathComponent(url.lastPathComponent); try fm.moveItem(at: url, to: target); return target }
    var record = SessionRecord(kind: .dictation, title: "Dictation"); record.transcript = "Hola"; record.status = .complete
    try? store.save(record)
    try? Data([1, 2, 3]).write(to: store.directory(for: record.id).appendingPathComponent("mic_part_00000.wav"))
    let trashed = try? store.moveToTrash(record.id, using: trash)
    expect(trashed != nil && !fm.fileExists(atPath: store.directory(for: record.id).path), "the whole folder leaves the store")
    expect((try? store.load())?.isEmpty == true, "a trashed record is not loaded")
    let restored = trashed.flatMap { try? store.restore(from: $0, id: record.id) }
    expect(restored?.transcript == "Hola" && fm.fileExists(atPath: store.directory(for: record.id).appendingPathComponent("mic_part_00000.wav").path),
           "restore brings back the record and its audio")
    let again = try? store.moveToTrash(record.id, using: trash)
    try? store.save(record)
    expect(again.map { (try? store.restore(from: $0, id: record.id)) == nil && fm.fileExists(atPath: $0.path) } == true, "restore never overwrites")
    let failing: (URL) throws -> URL = { _ in throw CocoaError(.fileWriteNoPermission) }
    expect((try? store.moveToTrash(record.id, using: failing)) == nil && fm.fileExists(atPath: store.directory(for: record.id).path),
           "a failed move leaves the folder in place")
    return failures
}
