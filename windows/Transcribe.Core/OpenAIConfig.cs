namespace Transcribe.Core;

/// <summary>
/// Auth + base-URL seam (proxy bearer, or a direct OpenAI key). Single provider seam,
/// mirroring the Swift <c>OpenAIConfig</c>.
/// </summary>
public sealed class OpenAIConfig
{
    /// <summary>e.g. https://api.openai.com/v1 or the Cloudflare Worker proxy.</summary>
    public Uri BaseUrl { get; }
    public string AuthName { get; }
    public string AuthValue { get; }

    public OpenAIConfig(Uri baseUrl, string authValue, string authName = "Authorization")
    {
        BaseUrl = baseUrl;
        AuthValue = authValue;
        AuthName = authName;
    }

    public bool HasKey => AuthValue != "Bearer " && !string.IsNullOrEmpty(AuthValue);

    /// <summary>Build from a bearer token (proxy team token or OpenAI key).</summary>
    public static OpenAIConfig FromToken(Uri baseUrl, string token) =>
        new(baseUrl, $"Bearer {token}");
}

/// <summary>
/// Central app config — mirrors the Swift <c>Config.swift</c>. <see cref="ProxyBaseUrl"/> is
/// the deployed Cloudflare Worker. When non-null, each person pastes their personal team token
/// (not an OpenAI key); the Worker swaps it for the org key server-side. Set it to null to fall
/// back to api.openai.com with a pasted OpenAI key.
/// </summary>
public static class AppConfig
{
    /// <summary>
    /// Identical to Config.swift's proxyBaseURL. Keep this the single source of truth.
    /// </summary>
    public static readonly Uri? ProxyBaseUrl =
        new("https://transcribe-proxy.quiet-bush-25b1.workers.dev/v1");

    public static Uri ApiBaseUrl => ProxyBaseUrl ?? new Uri("https://api.openai.com/v1");
}
