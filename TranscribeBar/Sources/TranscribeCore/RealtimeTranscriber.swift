import Foundation
import AVFoundation

/// Transport seam permits deterministic protocol tests without credentials or sockets.
public protocol LiveTranscriptionSocket: Sendable {
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close()
}

final class NativeLiveSocket: LiveTranscriptionSocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    init(request: URLRequest, session: URLSession) {
        task = session.webSocketTask(with: request)
        task.maximumMessageSize = 262_144
        task.resume()
    }
    func send(_ data: Data) async throws {
        guard let value = String(data: data, encoding: .utf8) else { throw ProviderError.invalidResponse }
        do { try await task.send(.string(value)) }
        catch { throw sanitizedTransportError() }
    }
    func receive() async throws -> Data {
        let message: URLSessionWebSocketTask.Message
        do { message = try await task.receive() }
        catch { throw sanitizedTransportError() }
        switch message {
        case .data(let data): return data
        case .string(let text): return Data(text.utf8)
        @unknown default: throw ProviderError.invalidResponse
        }
    }
    private func sanitizedTransportError() -> ProviderError {
        if let response = task.response as? HTTPURLResponse, response.statusCode != 101 {
            return classifiedProviderError(status: response.statusCode, body: Data())
        }
        return .unavailable
    }
    func close() { task.cancel(with: .normalClosure, reason: nil) }
}

struct LiveTranscriptionEvent: Sendable {
    let type: String
    let eventID: String?
    let itemID: String?
    let previousItemID: String?
    let hasPreviousItemID: Bool
    let text: String?
    let failure: ServiceFailureKind?
    let expiresAt: Double?
    static func parse(_ data: Data) throws -> Self {
        guard data.count <= 262_144,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { throw ProviderError.invalidResponse }
        let error = json["error"] as? [String: Any]
        var failure: ServiceFailureKind?
        if error != nil {
            let code = error?["code"] as? String
            let status: Int
            switch code {
            case "invalid_api_key", "not_authenticated": status = 401
            case "model_not_allowed", "permission_denied", "model_not_found", "access_denied", "account_deactivated": status = 403
            case "rate_limit_exceeded", "slow_down": status = 429
            default: status = 503
            }
            let safe = ["error": ["code": code ?? "", "type": error?["type"] as? String ?? ""]]
            failure = classifiedProviderError(status: status, body: try JSONSerialization.data(withJSONObject: safe)).failureKind
        }
        let session = json["session"] as? [String: Any]
        let expiry = session?["expires_at"] as? Double
        return .init(type: type, eventID: error?["event_id"] as? String ?? json["event_id"] as? String,
                     itemID: json["item_id"] as? String,
                     previousItemID: json["previous_item_id"] as? String,
                     hasPreviousItemID: json.keys.contains("previous_item_id"),
                     text: json["transcript"] as? String ?? json["delta"] as? String,
                     failure: failure, expiresAt: expiry?.isFinite == true ? expiry : nil)
    }
}

enum LiveProtocol {
    static let model = "gpt-live-transcribe"
    static let minimumCommitDuration = 0.25 // conservatively exceeds the 100 ms empty/short buffer boundary
    static let maximumTurnDuration = 10.0
    static let quietCommitDuration = 0.7
    static let signalRMS = 0.0001
    static func configuration(languages: [String], keywords: [String], eventID: String) throws -> Data {
        try checkedHints(languages: languages, keywords: keywords)
        var transcription: [String: Any] = ["model": model, "delay": "low"]
        if !languages.isEmpty { transcription["languages"] = languages }
        if !keywords.isEmpty { transcription["keywords"] = keywords }
        return try JSONSerialization.data(withJSONObject: ["type": "session.update", "event_id": eventID,
            "session": ["type": "transcription", "audio": ["input": [
                "format": ["type": "audio/pcm", "rate": 24_000], "transcription": transcription,
                "turn_detection": NSNull()]]]])
    }
    static func event(_ type: String, id: String, audio: Data? = nil) throws -> Data {
        var value: [String: Any] = ["type": type, "event_id": id]
        if let audio { value["audio"] = audio.base64EncodedString() }
        return try JSONSerialization.data(withJSONObject: value)
    }
}

/// Confined to the live engine. Raw files remain canonical 16 kHz float samples.
final class LivePCMEncoder {
    private let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    init() { reset() }
    func reset() { converter = AVAudioConverter(from: inputFormat, to: outputFormat) }
    func encode(_ frame: CapturedAudioFrame) throws -> Data {
        guard frame.pcmFloat32.count > 0, frame.pcmFloat32.count % 4 == 0,
              let converter,
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frame.pcmFloat32.count / 4)),
              let samples = input.floatChannelData?[0],
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(frame.pcmFloat32.count / 4 * 3 / 2 + 128))
        else { throw ProviderError.invalidResponse }
        input.frameLength = input.frameCapacity
        frame.pcmFloat32.withUnsafeBytes { bytes in samples.update(from: bytes.bindMemory(to: Float.self).baseAddress!, count: Int(input.frameLength)) }
        var supplied = false
        var failure: NSError?
        let result = converter.convert(to: output, error: &failure) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return input
        }
        guard result != .error, failure == nil, let data = output.int16ChannelData?[0] else { throw ProviderError.invalidResponse }
        return Data(bytes: data, count: Int(output.frameLength) * 2)
    }
    func finish() throws -> Data {
        guard let converter else { throw ProviderError.invalidResponse }
        var bytes = Data()
        // The converter's filter tail can exceed one small output buffer. Drain
        // through end-of-stream before sealing the matching raw audio interval.
        for _ in 0..<16 {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4_096) else { throw ProviderError.invalidResponse }
            var failure: NSError?
            let result = converter.convert(to: output, error: &failure) { _, state in state.pointee = .endOfStream; return nil }
            guard result != .error, failure == nil, let data = output.int16ChannelData?[0] else { throw ProviderError.invalidResponse }
            bytes.append(Data(bytes: data, count: Int(output.frameLength) * 2))
            if result == .endOfStream || output.frameLength == 0 { return bytes }
        }
        throw ProviderError.invalidResponse
    }
}
