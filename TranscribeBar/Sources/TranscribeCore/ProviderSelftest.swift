// Network-free provider, recovery and timeline checks for command-line-only Swift installs.
import Foundation
import AVFoundation

private final class StubProtocol: URLProtocol {
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

private final class TranscriptionTests {
    private var folder: URL!
    private var transport: URLSession!
    private let config = OpenAIConfig(baseURL: URL(string: "https://example.invalid/v1")!, authValue: "Bearer local-test-fixture")
    func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        transport = URLSession(configuration: configuration)
    }
    func tearDownWithError() throws {
        transport.invalidateAndCancel()
        StubProtocol.handler = nil
        try FileManager.default.removeItem(at: folder)
    }
    private func audio() throws -> URL {
        let url = folder.appendingPathComponent("input.m4a")
        try Data([1, 2, 3]).write(to: url)
        return url
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
    func testDictationUsesCurrentTextModelAndPluralHintsWithoutInventedSegments() async throws {
        let audio = try audio()
        StubProtocol.handler = { request in
            let text = self.body(request)
            XCTAssertTrue(text.contains("gpt-transcribe"))
            XCTAssertTrue(text.contains("name=\"languages[]\""))
            XCTAssertTrue(text.contains("name=\"keywords[]\""))
            XCTAssertFalse(text.contains("name=\"language\""))
            XCTAssertFalse(text.contains("timestamp_granularities"))
            return (200, Data(#"{"text":"Hello"}"#.utf8))
        }
        let result = try await requestAudioTranscript(fileURL: audio, model: .text,
            languages: ["en", "es"], keywords: ["Aanu"], config: config, session: transport)
        XCTAssertEqual(result.text, "Hello")
        XCTAssertTrue(result.segments.isEmpty)
    }
    func testDiarizationUsesSupportedFieldsAndRealTimes() async throws {
        let audio = try audio()
        StubProtocol.handler = { request in
            let text = self.body(request)
            XCTAssertTrue(text.contains("gpt-4o-transcribe-diarize"))
            XCTAssertTrue(text.contains("diarized_json")); XCTAssertTrue(text.contains("chunking_strategy"))
            XCTAssertFalse(text.contains("keywords[]")); XCTAssertFalse(text.contains("languages[]"))
            return (200, Data(#"{"text":"Hello","segments":[{"start":0.25,"end":0.75,"text":"Hello","speaker":"A"}]}"#.utf8))
        }
        let result = try await requestAudioTranscript(fileURL: audio, model: .diarized,
            languages: ["en", "es"], keywords: ["Aanu"], config: config, session: transport)
        XCTAssertEqual(result.segments.first?.start, 0.25)
        XCTAssertEqual(result.segments.first?.end, 0.75)
    }
    func testInvalidDictionaryHintIsRejectedBeforeHTTP() async throws {
        var count = 0
        StubProtocol.handler = { _ in count += 1; return (200, Data(#"{"text":""}"#.utf8)) }
        do {
            _ = try await requestAudioTranscript(fileURL: audio(), model: .text,
                keywords: ["wrong\nhint"], config: config, session: transport)
            XCTFail("Expected hint validation")
        } catch let error as ProviderError { XCTAssertEqual(error, .invalidHints) }
        XCTAssertEqual(count, 0)
    }
    func testSuccessfulRecognitionIsCachedBeforeAnotherRequest() async throws {
        var count = 0
        StubProtocol.handler = { _ in count += 1; return (200, Data(#"{"text":"Saved"}"#.utf8)) }
        let audio = try audio(), cache = folder.appendingPathComponent("cache")
        for _ in 0..<2 {
            let result = try await cachedAudioTranscript(fileURL: audio, model: .text, languages: [], keywords: [],
                                                        cacheDir: cache, config: config, session: transport)
            XCTAssertEqual(result.text, "Saved")
        }
        XCTAssertEqual(count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil).count, 1)
    }
    func testProviderErrorsDoNotEchoResponseContent() async throws {
        StubProtocol.handler = { _ in (401, Data("NEVER_ECHO_THIS_PROVIDER_BODY".utf8)) }
        do {
            _ = try await requestAudioTranscript(fileURL: audio(), model: .text, config: config, session: transport)
            XCTFail("Expected authentication error")
        } catch let error as ProviderError {
            XCTAssertEqual(error, .authentication)
            XCTAssertFalse(error.localizedDescription.contains("NEVER_ECHO"))
        }
    }
    func testFailedUploadIsNotReportedAsSilenceOrComplete() async throws {
        let source = try wav(name: "source.wav", value: 0.2, seconds: 0.5)
        var count = 0
        StubProtocol.handler = { _ in count += 1; return (503, Data("private upstream diagnostics".utf8)) }
        let result = try await transcribeFinal(tracks: [SessionAudioTrack(source: .mic,
            spans: [AudioSpan(url: source, offset: 0.1, duration: 0.5)])], kind: .dictation,
            chunkDir: folder.appendingPathComponent("work"), config: config, session: transport)
        XCTAssertFalse(result.complete); XCTAssertTrue(result.text.isEmpty)
        XCTAssertFalse(result.issues.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(count, 1)
    }
    func testBufferLivenessIncludesSilenceAndDetectsMissingTail() {
        var clock = AudioLiveness()
        clock.start(at: 100)
        XCTAssertEqual(clock.failure(at: 104), .noBuffers)
        // A silent PCM buffer is still received audio.
        clock.received(at: 104)
        XCTAssertEqual(clock.failure(at: 106), nil)
        XCTAssertEqual(clock.failure(at: 108), .stalled)
        clock.received(at: 109)
        XCTAssertEqual(clock.failure(at: 110), nil)
    }
    func testLongNotesAreBoundedAndRetainOriginalEvidence() async throws {
        let text = String(repeating: "Discussed work. ", count: 4_000)
        let turns = (0..<3).map { Segment(start: Double($0), end: Double($0 + 1), label: "You",
            text: text, source: .mic, idx: $0) }
        var count = 0
        StubProtocol.handler = { request in
            count += 1
            let body = self.body(request)
            XCTAssertTrue(body.count < 125_000)
            let sourceID = count == 4 ? "notes-0" : "turn-\(min(count - 1, 2))"
            let note = GeneratedNotes(text: "Discussed work.", evidence: [NoteEvidence(id: "claim", text: "Discussed work.", turnIDs: [sourceID])])
            let encoded = String(decoding: try JSONEncoder().encode(note), as: UTF8.self)
            return (200, try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": encoded]]]]))
        }
        let result = try await generateNotes(transcription: FinalTranscription(text: "", segments: turns,
            complete: true, issues: []), originalNotes: "Personal note", config: config, session: transport)
        XCTAssertEqual(count, 5)
        XCTAssertEqual(result.evidence.first?.turnIDs, ["turn-2"])
    }
    func testNotesRejectInventedEvidence() async throws {
        let turn = Segment(start: 0, end: 1, label: "You", text: "Discussion", source: .mic, idx: 0)
        StubProtocol.handler = { _ in
            let note = GeneratedNotes(text: "Invented", evidence: [NoteEvidence(id: "claim", text: "Invented", turnIDs: ["turn-999"])])
            let encoded = String(decoding: try JSONEncoder().encode(note), as: UTF8.self)
            return (200, try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": encoded]]]]))
        }
        do {
            _ = try await generateNotes(transcription: FinalTranscription(text: "", segments: [turn], complete: true, issues: []),
                originalNotes: "", config: config, session: transport)
            XCTFail("Expected invented evidence rejection")
        } catch let error as ProviderError { XCTAssertEqual(error, .invalidResponse) }
    }
    func testAlignedAudioPreservesGapAndBothSourceOffsets() throws {
        let first = try wav(name: "a.wav", value: 0.2, seconds: 0.5)
        let second = try wav(name: "b.wav", value: 0.4, seconds: 0.5)
        let output = folder.appendingPathComponent("aligned.wav")
        try writeAlignedAudio(tracks: [SessionAudioTrack(source: .mic, spans: [AudioSpan(url: first, offset: 0.5, duration: 0.5)]),
                                      SessionAudioTrack(source: .system, spans: [AudioSpan(url: second, offset: 1.5, duration: 0.5)])],
                              to: output, start: 0, duration: 2, mix: true)
        let file = try AVAudioFile(forReading: output)
        let samples = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 32_000)!
        try file.read(into: samples)
        let channel = samples.floatChannelData![0]
        XCTAssertEqual(channel[100], 0, accuracy: 0.001)
        XCTAssertEqual(channel[10_000], 0.1, accuracy: 0.001)
        XCTAssertEqual(channel[20_000], 0, accuracy: 0.001)
        XCTAssertEqual(channel[26_000], 0.2, accuracy: 0.001)
    }
    func testCaptureManifestRetainsHostClockGap() throws {
        let recorder = PCMTrackWriter(directory: folder, source: .mic, epoch: 100)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000)!
        buffer.frameLength = 8_000; buffer.floatChannelData![0].initialize(repeating: 0.2, count: 8_000)
        try recorder.append(buffer, pts: 100.25)
        try recorder.append(buffer, pts: 101.25)
        _ = recorder.stop()
        let recovered = recoverTracks(in: folder)
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered[0].spans.count, 2)
        XCTAssertEqual(recovered[0].spans[0].offset, 0.25, accuracy: 0.001)
        XCTAssertEqual(recovered[0].spans[1].offset, 1.25, accuracy: 0.001)
    }
    func testTimelineOpensOnlyCurrentPartsAndRejectsTruncatedAudio() throws {
        let source = try wav(name: "first.wav", value: 0.2, seconds: 1)
        XCTAssertEqual(try AVAudioFile(forReading: source).length, 16_000)
        let output = folder.appendingPathComponent("lazy.wav")
        let missing = folder.appendingPathComponent("missing.wav")
        do {
            try autoreleasepool {
                try writeAlignedAudio(tracks: [SessionAudioTrack(source: .mic, spans: [
                    AudioSpan(url: source, offset: 0, duration: 1), AudioSpan(url: missing, offset: 1, duration: 1)])],
                    to: output, start: 0, duration: 2, mix: false)
            }
            XCTFail("Expected missing later part")
        } catch {
            // The first second is rendered before the later missing file is opened.
            let length = try AVAudioFile(forReading: output).length
            if length != 16_000 { XCTFail("Lazy output frame count: \(length); fixture failure: \(error)") }
        }
        do {
            try writeAlignedAudio(tracks: [SessionAudioTrack(source: .mic, spans: [AudioSpan(url: source, offset: 0, duration: 2)])],
                to: folder.appendingPathComponent("truncated.wav"), start: 0, duration: 2, mix: false)
            XCTFail("Expected truncated section to fail, rather than silently pad its tail")
        } catch { }
    }
    func testRetryPreservesAcceptedSourceAndTurnIDsWithoutRawAudio() async throws {
        let microphone = try wav(name: "microphone.wav", value: 0.2, seconds: 0.5)
        let system = try wav(name: "system.wav", value: 0.4, seconds: 0.5)
        let tracks = [SessionAudioTrack(source: .mic, spans: [AudioSpan(url: microphone, offset: 0.25, duration: 0.5)]),
                      SessionAudioTrack(source: .system, spans: [AudioSpan(url: system, offset: 0.5, duration: 0.5)])]
        var requests = 0
        StubProtocol.handler = { _ in
            requests += 1
            if requests == 1 { return (503, Data("unavailable".utf8)) }
            return (200, Data(#"{"text":"Accepted","segments":[{"start":0.1,"end":0.3,"text":"Accepted","speaker":"A"}]}"#.utf8))
        }
        let work = folder.appendingPathComponent("work")
        let probe = folder.appendingPathComponent("probe.wav")
        do {
            try writeAlignedAudio(tracks: [tracks[0]], to: probe, start: 0.25, duration: 0.5, mix: false)
            _ = try segmentTrack(srcWAV: probe, outDir: folder, prefix: "probe")
        } catch { XCTFail("Fixture audio staging failed: \(error)"); return }
        let partial = try await transcribeFinal(tracks: tracks, kind: .onlineMeeting, chunkDir: work, config: config, session: transport)
        XCTAssertFalse(partial.complete)
        guard let accepted = partial.segments.first else {
            XCTFail("No accepted source; requests=\(requests), issues=\(partial.issues.map(\.userMessage).joined(separator: "; "))")
            return
        }
        let acceptedID = accepted.turnID
        XCTAssertEqual(accepted.source, .system)
        try FileManager.default.removeItem(at: system)
        try FileManager.default.removeItem(at: work.appendingPathComponent("system/final_chunk_000.m4a"))
        let complete = try await transcribeFinal(tracks: tracks, kind: .onlineMeeting, chunkDir: work, config: config, session: transport)
        XCTAssertTrue(complete.complete)
        XCTAssertEqual(requests, 3)
        XCTAssertEqual(complete.segments.first(where: { $0.source == .system })?.turnID, acceptedID)
        XCTAssertEqual(complete.segments.first(where: { $0.source == .system })?.start, 0.6)
    }
    func testRestartedCaptureRetainsEarlierParts() throws {
        let recorder = PCMTrackWriter(directory: folder, source: .system, epoch: 100)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000)!
        buffer.frameLength = 8_000; buffer.floatChannelData![0].initialize(repeating: 0.2, count: 8_000)
        try recorder.append(buffer, pts: 100.5)
        let first = recorder.stop().first!.url
        try recorder.append(buffer, pts: 102.5)
        let spans = recorder.stop()
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans[0].url, first)
        XCTAssertTrue(spans[0].url != spans[1].url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertEqual(spans[1].offset, 2.5)
    }
    private func wav(name: String, value: Float, seconds: Double) throws -> URL {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let url = folder.appendingPathComponent(name)
        let count = AVAudioFrameCount(seconds * 16_000)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
        buffer.frameLength = count; buffer.floatChannelData![0].initialize(repeating: value, count: Int(count))
        try file.write(from: buffer)
        return url
    }
}

private var contractFailures: [String] = []
private func XCTFail(_ message: String) { contractFailures.append(message) }
private func XCTAssertTrue(_ value: Bool) { if !value { XCTFail("Expected true") } }
private func XCTAssertFalse(_ value: Bool) { if value { XCTFail("Expected false") } }
private func XCTAssertEqual<T: Equatable>(_ first: T, _ second: T) { if first != second { XCTFail("Values differ") } }
private func XCTAssertEqual<T: BinaryFloatingPoint>(_ first: T, _ second: T, accuracy: T) {
    if abs(first - second) > accuracy { XCTFail("Timeline/audio value differs") }
}
public func runTranscriptionSelftests() async -> Bool {
    contractFailures = []
    let tests = TranscriptionTests()
    let cases: [(String, () async throws -> Void)] = [
        ("dictation format", tests.testDictationUsesCurrentTextModelAndPluralHintsWithoutInventedSegments),
        ("diarization format", tests.testDiarizationUsesSupportedFieldsAndRealTimes),
        ("dictionary validation", tests.testInvalidDictionaryHintIsRejectedBeforeHTTP),
        ("durable response cache", tests.testSuccessfulRecognitionIsCachedBeforeAnotherRequest),
        ("sanitized errors", tests.testProviderErrorsDoNotEchoResponseContent),
        ("failure vs silence", tests.testFailedUploadIsNotReportedAsSilenceOrComplete),
        ("gap alignment", { try tests.testAlignedAudioPreservesGapAndBothSourceOffsets() }),
        ("capture recovery", { try tests.testCaptureManifestRetainsHostClockGap() }),
        ("bounded file handles and truncated tail", { try tests.testTimelineOpensOnlyCurrentPartsAndRejectsTruncatedAudio() }),
        ("retry preserves accepted text and IDs", tests.testRetryPreservesAcceptedSourceAndTurnIDsWithoutRawAudio),
        ("capture restart preserves parts", { try tests.testRestartedCaptureRetainsEarlierParts() }),
        ("audio liveness and missing tail", { tests.testBufferLivenessIncludesSilenceAndDetectsMissingTail() }),
        ("bounded long notes", tests.testLongNotesAreBoundedAndRetainOriginalEvidence),
        ("notes evidence validation", tests.testNotesRejectInventedEvidence),
    ]
    for (name, body) in cases {
        let before = contractFailures.count
        do { try tests.setUpWithError(); try await body(); try tests.tearDownWithError() }
        catch { contractFailures.append(name + " threw an unexpected error"); try? tests.tearDownWithError() }
        if contractFailures.count != before {
            FileHandle.standardError.write(Data(("core contract FAILED: " + name + " " + contractFailures.dropFirst(before).joined(separator: "; ") + "\n").utf8))
        }
    }
    return contractFailures.isEmpty
}
