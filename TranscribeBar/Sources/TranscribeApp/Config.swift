import Foundation

enum ConnectionProvider: String, CaseIterable, Identifiable {
    case openAI, team
    var id: String { rawValue }
    var title: String { self == .openAI ? "OpenAI" : "Team" }
    var credentialLabel: String { self == .openAI ? "OpenAI API key" : "Team token" }
    var credentialPlaceholder: String { self == .openAI ? "OpenAI API key" : "Personal team token" }
    var setupTitle: String { self == .openAI ? "Connect OpenAI" : "Connect your team" }
    var baseURL: URL { self == .openAI ? Config.openAIBaseURL : Config.teamBaseURL }

    /// Verification checks access without creating audio or requesting generated text.
    func verificationRequest(credential: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(self == .openAI ? "models/gpt-transcribe" : "chat/completions"))
        request.timeoutInterval = 10
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        if self == .team {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = #"{"model":"__verify__"}"#.data(using: .utf8)
        } else { request.httpMethod = "GET" }
        return request
    }
}

enum Config {
    static let openAIBaseURL = URL(string: "https://api.openai.com/v1")!
    static let teamBaseURL = URL(string: "https://transcribe-proxy.quiet-bush-25b1.workers.dev/v1")!
}
