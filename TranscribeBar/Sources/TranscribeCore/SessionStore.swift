import Foundation

/// Synchronous atomic commits keep the coordinator's save-before-deliver order
/// explicit. Callers serialize updates; network/capture work never touches records.
public final class SessionStore {
    public let root: URL
    public private(set) var loadIssues: [String] = []
    private let fm = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(root: URL? = nil) throws {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory,
                     in: .userDomainMask).first!.appendingPathComponent("Transcribe/Sessions", isDirectory: true)
        encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        try fm.createDirectory(at: self.root, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
    }

    public func directory(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }

    public func save(_ record: SessionRecord) throws {
        let dir = directory(for: record.id)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let url = dir.appendingPathComponent("record.json")
        try encoder.encode(record).write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func load() throws -> [SessionRecord] {
        loadIssues = []
        let dirs = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        var records: [SessionRecord] = []
        for dir in dirs where UUID(uuidString: dir.lastPathComponent) != nil {
            do {
                var record = try decoder.decode(SessionRecord.self, from: Data(contentsOf: dir.appendingPathComponent("record.json")))
                guard record.id.uuidString == dir.lastPathComponent else { throw CocoaError(.fileReadCorruptFile) }
                if record.liveMeetingVersion != nil && record.status.interrupted {
                    // A live record can already hold earlier parts while capture manifests
                    // contain a longer current part. Always reconcile the actual tail.
                    let captured = recoverTracks(in: dir)
                    if !captured.isEmpty { record.tracks = captured }
                }
                if record.tracks.isEmpty && (record.status.interrupted || record.status == .cancelled || record.status == .failed || record.status == .partial) {
                    let captured = recoverTracks(in: dir)
                    if !captured.isEmpty {
                        record.tracks = captured
                        if record.status == .cancelled { record.captureIncomplete = true }
                        try save(record)
                    }
                }
                if record.status.interrupted {
                    let captureWasActive = record.status == .starting || record.status == .recording
                    record.status = .failed; record.delivery = record.kind == .dictation ? .ready : .never
                    record.issues.append("Recording interrupted")
                    record.captureIncomplete = record.captureIncomplete || captureWasActive
                    // Recover already finalized audio even if capture ended before its
                    // result reached the coordinator. Never remove unknown files.
                    if record.tracks.isEmpty {
                        record.tracks = recoverTracks(in: dir)
                    }
                    if record.summaryStatus == .processing { record.summaryStatus = .failed }
                    try save(record)
                } else if record.delivery == .eligible {
                    record.delivery = .ready; try save(record)
                }
                if record.summaryStatus == .processing {
                    record.summaryStatus = .failed; try save(record)
                }
                records.append(record)
            } catch { loadIssues.append("A saved recording could not be opened") }
        }
        return records.sorted { $0.startedAt > $1.startedAt }
    }

    public func importMarkdown(from folder: URL, existing: [SessionRecord]) throws -> [SessionRecord] {
        let imported = try Self.discoverMarkdown(from: folder, existing: existing)
        for record in imported { try save(record) }
        return imported
    }

    /// Read only on a utility executor after the user chooses Import. Documents
    /// can involve file providers and privacy dialogs and must not block launch.
    public static func discoverMarkdown(from folder: URL, existing: [SessionRecord]) throws -> [SessionRecord] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.path) else { return [] }
        let urls = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])
        let known = Set(existing.flatMap { [$0.importURL, $0.exportURL].compactMap { $0?.standardizedFileURL.path } })
        var imported: [SessionRecord] = []
        for url in urls where url.pathExtension.lowercased() == "md" && !known.contains(url.standardizedFileURL.path) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let date = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
            var record = SessionRecord(kind: .meeting, title: url.deletingPathExtension().lastPathComponent, startedAt: date)
            record.status = .complete; record.delivery = .never; record.transcript = text
            record.exportURL = url; record.importURL = url; record.imported = true
            imported.append(record)
        }
        return imported
    }

    /// Called only after durable, complete text, capture completion and final readers.
    /// Delete only referenced artifacts belonging to this UUID directory.
    public func cleanAudio(for record: SessionRecord) throws {
        guard record.status == .complete, !record.captureIncomplete, record.hasSealedMeetingAudio else { return }
        let owned = directory(for: record.id).standardizedFileURL.path + "/"
        for url in record.tracks.flatMap({ $0.spans.map(\.url) }) {
            guard url.standardizedFileURL.path.hasPrefix(owned) else { continue }
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        }
        let chunks = directory(for: record.id).appendingPathComponent("chunks", isDirectory: true)
        if fm.fileExists(atPath: chunks.path) { try fm.removeItem(at: chunks) }
    }
}
