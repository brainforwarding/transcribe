using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Transcribe.Core;

/// <summary>
/// chat/completions client: the meeting summary (gpt-4o) and the token verification probe.
/// Ports Swift <c>summarize</c> and the AppModel <c>verifyToken</c>.
/// </summary>
public sealed class Summarizer
{
    private readonly HttpClient _http;

    public Summarizer(HttpClient http)
    {
        _http = http;
    }

    private sealed class ChatResponse
    {
        [JsonPropertyName("choices")] public List<Choice>? Choices { get; set; }
        public sealed class Choice
        {
            [JsonPropertyName("message")] public Msg? Message { get; set; }
        }
        public sealed class Msg
        {
            [JsonPropertyName("content")] public string? Content { get; set; }
        }
    }

    /// <summary>
    /// The exact meetrec.py summary prompt prefix. Kept verbatim so Mac and Windows summaries
    /// are produced from an identical instruction.
    /// </summary>
    public const string SummaryPromptPrefix =
        "Summarize this meeting transcript. Return: a 3-5 sentence overview, then a "
        + "bulleted list of decisions, then a bulleted list of action items with an owner if "
        + "one is mentioned.\n\n";

    /// <summary>Build the chat request JSON body for a summary. Pure; unit-tested.</summary>
    public static string BuildSummaryBody(string transcript, string model)
    {
        var payload = new
        {
            model,
            messages = new[]
            {
                new { role = "user", content = SummaryPromptPrefix + transcript }
            }
        };
        return JsonSerializer.Serialize(payload);
    }

    /// <summary>
    /// Port of meetrec.py <c>summarize</c> / Swift <c>summarize</c>. Best-effort; returns null
    /// on any failure (network, non-2xx, empty content).
    /// </summary>
    public async Task<string?> SummarizeAsync(OpenAIConfig config, string transcript,
        string model = "gpt-4o", CancellationToken ct = default)
    {
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Post,
                CombineUri(config.BaseUrl, "chat/completions"));
            req.Headers.TryAddWithoutValidation(config.AuthName, config.AuthValue);
            req.Content = new StringContent(BuildSummaryBody(transcript, model),
                Encoding.UTF8, "application/json");

            using var resp = await _http.SendAsync(req, ct).ConfigureAwait(false);
            if (!resp.IsSuccessStatusCode) return null;
            var body = await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
            var decoded = JsonSerializer.Deserialize<ChatResponse>(body);
            var text = decoded?.Choices?.FirstOrDefault()?.Message?.Content?.Trim();
            return string.IsNullOrEmpty(text) ? null : text;
        }
        catch
        {
            return null;
        }
    }

    public enum VerifyResult { Accepted, Rejected, Unreachable }

    /// <summary>
    /// Token verification: POST chat/completions with <c>{"model":"__verify__"}</c>. HTTP 401 =
    /// rejected; any other status = recognized (accepted); a network failure = unreachable.
    /// Mirrors the AppModel <c>verifyToken</c> contract exactly.
    /// </summary>
    public async Task<VerifyResult> VerifyTokenAsync(Uri baseUrl, string token,
        CancellationToken ct = default)
    {
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Post,
                CombineUri(baseUrl, "chat/completions"));
            req.Headers.TryAddWithoutValidation("Authorization", $"Bearer {token}");
            req.Content = new StringContent("{\"model\":\"__verify__\"}",
                Encoding.UTF8, "application/json");

            using var resp = await _http.SendAsync(req, ct).ConfigureAwait(false);
            return (int)resp.StatusCode == 401 ? VerifyResult.Rejected : VerifyResult.Accepted;
        }
        catch
        {
            return VerifyResult.Unreachable;
        }
    }

    private static Uri CombineUri(Uri baseUrl, string relative)
    {
        var b = baseUrl.AbsoluteUri.TrimEnd('/');
        return new Uri($"{b}/{relative}");
    }
}
