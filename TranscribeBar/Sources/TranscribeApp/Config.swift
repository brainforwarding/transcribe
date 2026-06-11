import Foundation

enum Config {
    /// Auth mode. `nil` = per-user OpenAI key in the Keychain, called against
    /// api.openai.com directly. When set to the deployed Cloudflare Worker URL, requests
    /// route through the shared-key proxy: each person pastes their personal team token
    /// (not an OpenAI key) where the app asks for the key, and the Worker swaps it for
    /// the org key server-side (see proxy/README.md).
    static let proxyBaseURL: URL? = URL(string: "https://transcribe-proxy.quiet-bush-25b1.workers.dev/v1")

    static var apiBaseURL: URL {
        proxyBaseURL ?? URL(string: "https://api.openai.com/v1")!
    }
}
