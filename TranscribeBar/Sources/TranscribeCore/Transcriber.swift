import Foundation

struct RuntimeError: Error, CustomStringConvertible {
    let message: String
    init(_ m: String) { message = m }
    var description: String { message }
}

extension Data {
    mutating func appendString(_ s: String) { append(s.data(using: .utf8)!) }
}

// MARK: - verbose_json schema (whisper-1). Optionals guarded per the Python contract.

public struct WhisperSegment: Decodable {
    public let start: Double
    public let end: Double
    public let text: String?
    public let avgLogprob: Double?
    public let noSpeechProb: Double?
    enum CodingKeys: String, CodingKey {
        case start, end, text
        case avgLogprob = "avg_logprob"
        case noSpeechProb = "no_speech_prob"
    }
}

public struct VerboseTranscription: Decodable {
    public let language: String?
    public let duration: Double?
    public let text: String?
    public let segments: [WhisperSegment]?
}

// MARK: - Auth (proxy base-URL + bearer, or direct key). Single provider seam.

public struct OpenAIConfig: Sendable {
    public var baseURL: URL                 // e.g. https://api.openai.com/v1  or  the proxy
    public var authName: String
    public var authValue: String
    public init(baseURL: URL, authName: String = "Authorization", authValue: String) {
        self.baseURL = baseURL
        self.authName = authName
        self.authValue = authValue
    }
    /// Dev/headless config from env: OPENAI_BASE_URL (default api.openai.com/v1) + OPENAI_API_KEY.
    public static func fromEnv() -> OpenAIConfig {
        let env = ProcessInfo.processInfo.environment
        let base = env["OPENAI_BASE_URL"] ?? "https://api.openai.com/v1"
        let key = env["OPENAI_API_KEY"] ?? ""
        return OpenAIConfig(baseURL: URL(string: base)!, authValue: "Bearer \(key)")
    }
    public var hasKey: Bool { authValue != "Bearer " && !authValue.isEmpty }
}

/// One chunk → whisper-1 verbose_json. Multipart hand-built (no SDK); note the literal
/// `timestamp_granularities[]` field name and the per-file Content-Type.
public func transcribeChunk(fileURL: URL, language: String?, config: OpenAIConfig) async throws -> VerboseTranscription {
    let boundary = "Boundary-\(UUID().uuidString)"
    var req = URLRequest(url: config.baseURL.appendingPathComponent("audio/transcriptions"))
    req.httpMethod = "POST"
    req.setValue(config.authValue, forHTTPHeaderField: config.authName)
    req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

    var body = Data()
    func field(_ name: String, _ value: String) {
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        body.appendString("\(value)\r\n")
    }
    field("model", "whisper-1")
    field("response_format", "verbose_json")
    field("timestamp_granularities[]", "segment")   // literal brackets, one part
    if let language, !language.isEmpty { field("language", language) }

    let fileData = try Data(contentsOf: fileURL)
    body.appendString("--\(boundary)\r\n")
    body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n")
    body.appendString("Content-Type: audio/mp4\r\n\r\n")
    body.append(fileData)
    body.appendString("\r\n")
    body.appendString("--\(boundary)--\r\n")
    req.httpBody = body

    let (data, resp) = try await URLSession.shared.data(for: req)
    guard let http = resp as? HTTPURLResponse else { throw RuntimeError("no HTTP response") }
    guard (200..<300).contains(http.statusCode) else {
        let msg = String(data: data, encoding: .utf8) ?? "<binary>"
        throw RuntimeError("HTTP \(http.statusCode): \(msg.prefix(400))")
    }
    return try JSONDecoder().decode(VerboseTranscription.self, from: data)
}

// MARK: - Summary (chat.completions)

private struct ChatResponse: Decodable {
    struct Choice: Decodable { struct Msg: Decodable { let content: String? }; let message: Msg }
    let choices: [Choice]
}

/// Port of meetrec.py `summarize`. Best-effort; returns nil on any failure.
public func summarize(_ transcript: String, model: String = "gpt-4o", config: OpenAIConfig) async -> String? {
    let prompt = "Summarize this meeting transcript. Return: a 3-5 sentence overview, then a "
        + "bulleted list of decisions, then a bulleted list of action items with an owner if "
        + "one is mentioned.\n\n" + transcript
    var req = URLRequest(url: config.baseURL.appendingPathComponent("chat/completions"))
    req.httpMethod = "POST"
    req.setValue(config.authValue, forHTTPHeaderField: config.authName)
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let body: [String: Any] = ["model": model,
                               "messages": [["role": "user", "content": prompt]]]
    req.httpBody = try? JSONSerialization.data(withJSONObject: body)
    guard let (data, resp) = try? await URLSession.shared.data(for: req),
          let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
          let decoded = try? JSONDecoder().decode(ChatResponse.self, from: data),
          let text = decoded.choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines),
          !text.isEmpty
    else { return nil }
    return text
}

/// Port of meetrec.py `transcribe_track_whisper`. Per-chunk failures CONTINUE (best-effort,
/// partial transcript). Returns segments + the next idx so the caller keeps a global
/// input-order counter (mic track first, then system) for the merge tiebreak.
public func transcribeTrack(chunks: [(url: URL, offset: Double)],
                            baseOffset: Double,
                            label: String,
                            source: Source,
                            language: String?,
                            config: OpenAIConfig,
                            startIdx: Int) async -> (segments: [Segment], nextIdx: Int) {
    var segs: [Segment] = []
    var idx = startIdx
    for (i, chunk) in chunks.enumerated() {
        let attrs = try? FileManager.default.attributesOfItem(atPath: chunk.url.path)
        let size = (attrs?[.size] as? Int) ?? 0
        if size < 256 {
            FileHandle.standardError.write("  skip \(chunk.url.lastPathComponent) (empty)\n".data(using: .utf8)!)
            continue
        }
        FileHandle.standardError.write("Transcribing \(source) chunk \(i + 1)/\(chunks.count)…\n".data(using: .utf8)!)
        let resp: VerboseTranscription
        do {
            resp = try await transcribeChunk(fileURL: chunk.url, language: language, config: config)
        } catch {
            FileHandle.standardError.write("  \(source) chunk \(i + 1) failed: \(error)\n".data(using: .utf8)!)
            continue
        }
        let off = baseOffset + chunk.offset
        for s in resp.segments ?? [] {
            let txt = (s.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if txt.isEmpty { continue }
            let nsp = s.noSpeechProb ?? 0.0
            let alp = s.avgLogprob ?? 0.0
            if nsp > 0.6 && alp < -1.0 { continue }   // drop silence-hallucinations
            let st = s.start + off
            let en = max(s.end + off, st)
            segs.append(Segment(start: st, end: en, label: label, text: txt, source: source, idx: idx))
            idx += 1
        }
    }
    return (segs, idx)
}
