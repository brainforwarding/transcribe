// Network-free checks for dropped audio files. Fixtures are synthesized tones only.
import Foundation
import AVFoundation

private final class ImportStubProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                                                                httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private final class AudioImportChecks {
    var failures: [String] = []
    func check(_ condition: Bool, _ message: String = "", line: UInt = #line) { if !condition { failures.append("AudioImportSelftest:\(line) \(message)") } }
    private var folder: URL!
    private var store: SessionStore!
    private var transport: URLSession!
    private let config = OpenAIConfig(baseURL: URL(string: "https://example.invalid/v1")!, authValue: "Bearer local-test-fixture")
    func setUp() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = try SessionStore(root: folder.appendingPathComponent("Sessions"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImportStubProtocol.self]
        transport = URLSession(configuration: configuration)
    }
    func tearDown() {
        transport.invalidateAndCancel(); ImportStubProtocol.handler = nil
        try? FileManager.default.removeItem(at: folder)
    }
    private func storeEntries() -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: store.root.path)) ?? [] }

    /// Left channel 0.4, right channel 0: a mixdown lands between the two.
    private func tone(_ name: String, seconds: Double, rate: Double, channels: AVAudioChannelCount, settings: [String: Any]) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        var remaining = AVAudioFrameCount(seconds * rate)
        while remaining > 0 {
            let count = min(remaining, 65_536)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
            buffer.frameLength = count
            buffer.floatChannelData![0].initialize(repeating: 0.4, count: Int(count))
            if channels > 1 { buffer.floatChannelData![1].initialize(repeating: 0, count: Int(count)) }
            try file.write(from: buffer); remaining -= count
        }
        return url
    }
    private func pcm(rate: Double, channels: Int) -> [String: Any] {
        [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
         AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
    }

    func testRejectedFilesLeaveNothing() async throws {
        let garbage = folder.appendingPathComponent("garbage.m4a"); try Data("not audio at all".utf8).write(to: garbage)
        let webm = folder.appendingPathComponent("clip.webm"); try Data([0x1A, 0x45, 0xDF, 0xA3, 0, 0, 0, 0]).write(to: webm)
        let empty = folder.appendingPathComponent("empty.wav"); try Data().write(to: empty)
        let silentWAV = try tone("zero.wav", seconds: 0, rate: 16_000, channels: 1, settings: pcm(rate: 16_000, channels: 1))
        for url in [garbage, webm, empty, silentWAV, folder.appendingPathComponent("missing.mp3")] {
            var threw = false
            do { _ = try await store.importAudioFile(url) } catch { threw = true }
            check(threw, url.lastPathComponent)
            check(storeEntries().isEmpty, "leftover after \(url.lastPathComponent)")
        }
        check(try store.load().isEmpty)
        check(FileManager.default.fileExists(atPath: webm.path) && FileManager.default.fileExists(atPath: garbage.path), "sources kept")
    }

    func testStereoWAVBecomesContiguousMicParts() async throws {
        let source = try tone("Team sync .wav", seconds: 100, rate: 44_100, channels: 2, settings: pcm(rate: 44_100, channels: 2))
        let before = try audioDigest(source)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let record = try await store.importAudioFile(source, now: now)
        let final = store.directory(for: record.id).standardizedFileURL.path + "/"
        check(record.kind == .meeting && record.meetingMode == .inPerson && record.status == .processing && record.delivery == .never)
        check(record.title == "Team sync" && record.titleIsAutomatic && !record.imported && record.startedAt == now && record.importedAudio == nil)
        check(record.tracks.count == 1 && record.tracks.first?.source == .mic, "one mic track")
        let spans = record.tracks.first?.spans ?? []
        check(spans.map(\.url.lastPathComponent) == ["mic_part_00000.wav", "mic_part_00001.wav", "mic_part_00002.wav"], "three parts")
        check(spans.first?.offset == 0)
        for pair in zip(spans, spans.dropFirst()) { check(pair.1.offset == pair.0.offset + pair.0.duration, "contiguous") }
        check(spans.prefix(2).allSatisfy { $0.duration == 45 }, "45 s parts")
        check(abs(record.duration - 100) < 0.01 && abs(spans.map(\.duration).reduce(0, +) - record.duration) < 1e-9, "duration \(record.duration)")
        for span in spans {
            check(span.url.standardizedFileURL.path.hasPrefix(final), "inside final folder")
            let file = try AVAudioFile(forReading: span.url)
            check(file.processingFormat.sampleRate == 16_000 && file.processingFormat.channelCount == 1 && file.processingFormat.commonFormat == .pcmFormatFloat32)
            check(abs(Double(file.length) / 16_000 - span.duration) < 1e-9, "part length")
        }
        if let first = spans.first {
            let file = try AVAudioFile(forReading: first.url)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_000)!
            try file.read(into: buffer, frameCount: 16_000)
            let middle = buffer.floatChannelData![0][8_000]
            check(middle > 0.1 && middle < 0.35, "stereo mixed to mono (\(middle))")
        }
        check(storeEntries() == [record.id.uuidString], "only the record folder")
        check(try audioDigest(source) == before, "source untouched")
        let loaded = try store.load()
        check(loaded.count == 1 && loaded.first?.tracks == record.tracks)
        check(loaded.first?.status == .failed && loaded.first?.canRecover == true, "interrupted import offers Retry")
        check(spans.allSatisfy { (try? validateCapturedMeetingInterval(track: record.tracks[0], start: $0.offset, end: $0.offset + $0.duration)) != nil },
              "pipeline accepts the timeline")
    }

    func testCompressedFormatsAdmit() async throws {
        let m4a = try tone("Memo.m4a", seconds: 3, rate: 48_000, channels: 1,
                           settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1])
        let caf = try tone("Room.caf", seconds: 2, rate: 22_050, channels: 2, settings: pcm(rate: 22_050, channels: 2))
        for (url, length) in [(m4a, 3.0), (caf, 2.0)] {
            let record = try await store.importAudioFile(url)
            check(record.tracks.first?.spans.count == 1, url.lastPathComponent)
            check(abs(record.duration - length) < 0.1, "\(url.lastPathComponent) \(record.duration)")
        }
        check(try store.load().count == 2)
    }

    func testOggIsCopiedWholeAndRecoverable() async throws {
        let source = folder.appendingPathComponent("WhatsApp Audio.opus")
        let bytes = Data("OggS".utf8) + Data((0..<512).map { UInt8($0 % 251) })
        try bytes.write(to: source)
        var record = try await store.importAudioFile(source)
        let copy = store.directory(for: record.id).appendingPathComponent("audio.ogg")
        check(record.importedAudio == copy && record.tracks.isEmpty && record.duration == 0 && record.title == "WhatsApp Audio")
        check((try? Data(contentsOf: copy)) == bytes && (try? Data(contentsOf: source)) == bytes, "copy equals source")
        check(!record.canRecover, "processing is not recoverable")
        record.status = .failed
        check(record.canRecover, "failed Ogg offers Retry")
        let loaded = try store.load().first
        check(loaded?.status == .failed && loaded?.canRecover == true && loaded?.importedAudio == copy, "relaunch keeps Ogg retry")
    }

    func testLoadRemovesOnlyStaleImportFolders() throws {
        let stale = store.root.appendingPathComponent(importFolderPrefix + UUID().uuidString + "-" + UUID().uuidString)
        let active = store.root.appendingPathComponent(importFolderPrefix + importProcessToken + "-" + UUID().uuidString)
        for dir in [stale, active] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data([1]).write(to: dir.appendingPathComponent("mic_part_00000.wav"))
        }
        check(try store.load().isEmpty)
        check(!FileManager.default.fileExists(atPath: stale.path), "crash leftover removed")
        check(FileManager.default.fileExists(atPath: active.path), "import in progress kept")
    }

    func testCleanupDeletesOggCopyAndClearsField() async throws {
        let source = folder.appendingPathComponent("note.ogg"); try Data("OggS-fixture".utf8).write(to: source)
        var record = try await store.importAudioFile(source)
        let copy = try XCTUnwrap(record.importedAudio)
        record.status = .processing
        check(try store.cleanAudio(for: record).importedAudio == copy, "incomplete keeps the copy")
        record.status = .complete; record.transcript = "[00:00] **Microphone:** Hola"; try store.save(record)
        let cleaned = try store.cleanAudio(for: record)
        check(cleaned.importedAudio == nil && !FileManager.default.fileExists(atPath: copy.path), "copy deleted")
        check(try store.load().first?.importedAudio == nil, "saved without the copy")
        check(FileManager.default.fileExists(atPath: source.path), "source kept")
    }
    private func XCTUnwrap<T>(_ value: T?) throws -> T { guard let value else { throw CocoaError(.fileReadCorruptFile) }; return value }

    func testMIMETypes() {
        check(audioMIMEType(for: URL(fileURLWithPath: "/a/audio.ogg")) == "audio/ogg")
        check(audioMIMEType(for: URL(fileURLWithPath: "/a/x.OPUS")) == "audio/ogg")
        check(audioMIMEType(for: URL(fileURLWithPath: "/a/x.wav")) == "audio/wav")
        check(audioMIMEType(for: URL(fileURLWithPath: "/a/x.m4a")) == "audio/mp4")
    }

    private func body(_ request: URLRequest) -> String {
        if let data = request.httpBody { return String(decoding: data, as: UTF8.self) }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open(); defer { stream.close() }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count))
        }
        return String(decoding: data, as: UTF8.self)
    }

    func testOggUploadsOnceDiarizedAndMapsSegments() async throws {
        let audio = folder.appendingPathComponent("audio.ogg"); try Data("OggS-voice-note".utf8).write(to: audio)
        let chunks = folder.appendingPathComponent("chunks")
        var requests = 0
        ImportStubProtocol.handler = { request in
            requests += 1
            let text = self.body(request)
            self.check(text.contains("gpt-4o-transcribe-diarize") && text.contains("diarized_json"), "diarized model")
            self.check(text.contains("filename=\"audio.ogg\"") && text.contains("Content-Type: audio/ogg"), "ogg upload")
            self.check(text.contains("OggS-voice-note") && !text.contains("keywords[]"), "whole file, no keywords")
            return (200, Data(#"{"text":"Hola. Sí.","segments":[{"start":1900.5,"end":1902,"text":" Sí. ","speaker":"B"},{"start":0.5,"end":2,"text":"Hola.","speaker":"A"},{"start":3,"end":4,"text":"  ","speaker":"A"}]}"#.utf8))
        }
        let result = try await transcribeImportedAudio(audio, chunkDir: chunks, languages: ["es"], config: config, session: transport)
        check(requests == 1 && result.complete && result.issues.isEmpty)
        check(result.segments.map(\.text) == ["Hola.", "Sí."], "sorted, trimmed, empty dropped")
        check(result.segments.allSatisfy { $0.label == "Microphone" && $0.source == .mic }, "mic labels")
        check(result.segments.map(\.idx) == [1, 0], "transcribeFinal idx scheme")
        check(result.text == renderConversation(result.segments, timestamps: true))
        check(result.lastSegmentEnd == 1902, "length from last segment, no duration guard")
        let again = try await transcribeImportedAudio(audio, chunkDir: chunks, languages: ["es"], config: config, session: transport)
        check(requests == 1 && again.segments == result.segments, "retry reads the cache")
    }

    func testDictationImportIsPlainTextWithHints() async throws {
        let source = folder.appendingPathComponent("Nota de voz.opus"); try Data("OggS-dictation".utf8).write(to: source)
        let record = try await store.importAudioFile(source, kind: .dictation, languages: ["en", "es"], keywords: ["Circles"])
        check(record.kind == .dictation && record.delivery == .never && !record.titleIsAutomatic, "a dictation that is never pasted")
        check(record.importedFrom == "Nota de voz.opus" && record.languages == ["en", "es"] && record.keywords == ["Circles"], "file name and hints kept")
        var requests = 0
        ImportStubProtocol.handler = { request in
            requests += 1
            let text = self.body(request)
            self.check(!text.contains("diarize") && text.contains("languages[]") && text.contains("keywords[]"), "plain model with hints")
            return (200, Data(#"{"text":"  Hola, esto es una nota.  "}"#.utf8))
        }
        let result = try await transcribeImportedAudio(try XCTUnwrap(record.importedAudio), chunkDir: folder.appendingPathComponent("d1"),
                                                       kind: .dictation, languages: record.languages, keywords: record.keywords,
                                                       config: config, session: transport)
        check(requests == 1 && result.complete && result.text == "Hola, esto es una nota." && result.segments.isEmpty, "plain text")
    }

    func testOggFailuresUseTranscribeFinalIssues() async throws {
        let big = folder.appendingPathComponent("audio.ogg")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big); try handle.truncate(atOffset: 24_000_001); try handle.close()
        var requests = 0
        ImportStubProtocol.handler = { _ in requests += 1; return (500, Data()) }
        let tooLarge = try await transcribeImportedAudio(big, chunkDir: folder.appendingPathComponent("c1"), config: config, session: transport)
        check(!tooLarge.complete && tooLarge.issues.first?.failureKind == .tooLarge && tooLarge.issues.first?.retryable == false && requests == 0, "24 MB guard")
        let small = folder.appendingPathComponent("small.ogg"); try Data("OggS".utf8).write(to: small)
        let unavailable = try await transcribeImportedAudio(small, chunkDir: folder.appendingPathComponent("c2"), config: config, session: transport)
        check(!unavailable.complete && unavailable.issues.first?.source == .mic && unavailable.issues.first?.retryable == true && requests == 1, "service failure")
        let missing = try await transcribeImportedAudio(folder.appendingPathComponent("gone.ogg"), chunkDir: folder.appendingPathComponent("c3"), config: config, session: transport)
        check(missing.issues.first?.failureKind == .storage && requests == 1, "missing copy")
    }
}

public func runAudioImportSelftests() async -> Bool {
    let checks = AudioImportChecks()
    let tests: [(String, () async throws -> Void)] = [
        ("import: rejected files leave no record or folder", checks.testRejectedFilesLeaveNothing),
        ("import: stereo 44.1 kHz WAV becomes contiguous mic parts", checks.testStereoWAVBecomesContiguousMicParts),
        ("import: M4A and CAF admit", checks.testCompressedFormatsAdmit),
        ("import: Ogg copied whole and recoverable", checks.testOggIsCopiedWholeAndRecoverable),
        ("import: load removes only stale temporary folders", { try checks.testLoadRemovesOnlyStaleImportFolders() }),
        ("import: cleanup deletes the Ogg copy", checks.testCleanupDeletesOggCopyAndClearsField),
        ("import: MIME types", { checks.testMIMETypes() }),
        ("import: Ogg upload is one diarized request", checks.testOggUploadsOnceDiarizedAndMapsSegments),
        ("import: Ogg failures match transcribeFinal", checks.testOggFailuresUseTranscribeFinalIssues),
        ("import: a dictation file is plain text with hints", checks.testDictationImportIsPlainTextWithHints),
    ]
    for (name, test) in tests {
        let before = checks.failures.count
        do { try checks.setUp(); try await test() }
        catch { checks.failures.append("Failed: \(name) threw \(error)") }
        checks.tearDown()
        print("\(checks.failures.count == before ? "PASS" : "FAIL") \(name)")
    }
    for failure in checks.failures { print(failure) }
    return checks.failures.isEmpty
}
