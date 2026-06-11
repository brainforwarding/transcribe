import Foundation

enum Config {
    /// Auth mode. Default (`nil`) = per-user OpenAI key in the Keychain, called against
    /// api.openai.com directly. Set this to your deployed Cloudflare Worker URL (e.g.
    /// `https://transcribe-proxy.you.workers.dev/v1`) to route through the shared-key proxy.
    /// When set, also swap the Keychain value for the Cloudflare Access SSO token (see
    /// proxy/README.md — the SSO sign-in flow is the remaining integration for that mode).
    static let proxyBaseURL: URL? = nil

    static var apiBaseURL: URL {
        proxyBaseURL ?? URL(string: "https://api.openai.com/v1")!
    }
}
