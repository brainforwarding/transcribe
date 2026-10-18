import Foundation

private final class AssemblyFixtureProtocol: URLProtocol {
    static var count = 0
    static var body = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream, body.isEmpty {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 8192)
            while stream.hasBytesAvailable {
                let size = stream.read(&buffer, maxLength: buffer.count)
                if size <= 0 { break }; body.append(contentsOf: buffer.prefix(size))
            }
        }
        Self.count += 1; Self.body = body
        let text = "This is very very important. Do not send 17 euros."
        let data = try! JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": text]]]])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

public func runDictationAssemblySelftests() async -> Bool {
    do {
        AssemblyFixtureProtocol.count = 0
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AssemblyFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let turns: [MeetingTurn] = [
            .init(idx: 1, source: .mic, start: 18, end: 30, state: .confirmed, text: "very important do not send 17 euros"),
            .init(idx: 0, source: .mic, start: 0, end: 20, state: .confirmed, text: "this is very very important")]
        let result = try await assembleDictation(turns, config: .init(baseURL: URL(string: "https://fixture.invalid/v1")!, authValue: "Bearer local-fixture"), session: session)
        let request = try JSONSerialization.jsonObject(with: AssemblyFixtureProtocol.body) as! [String: Any]
        let messages = request["messages"] as! [[String: String]]
        let payload = try JSONSerialization.jsonObject(with: Data(messages[1]["content"]!.utf8)) as! [String: Any]
        let chunks = payload["chunks"] as! [[String: Any]]
        return AssemblyFixtureProtocol.count == 1 && result.failure == nil
            && request["service_tier"] as? String == "fast"
            && result.text == "This is very very important. Do not send 17 euros."
            && chunks.count == 2 && chunks[0]["start_seconds"] as? Double == 0
            && chunks[1]["overlap_with_previous_seconds"] as? Double == 2
            && messages[0]["content"]!.contains("genuine spoken repetitions")
    } catch { return false }
}
