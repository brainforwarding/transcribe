using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;

namespace Transcribe.Core;

/// <summary>
/// Whisper HTTP client + the silence-hallucination filter + the best-effort per-track loop.
/// Direct port of meetrec.py <c>transcribe_track_whisper</c> and Swift
/// <c>transcribeChunk</c> / <c>transcribeTrack</c>. The multipart contract is hand-built to
/// match the macOS app byte-for-byte: <c>model=whisper-1</c>, <c>response_format=verbose_json</c>,
/// the literal <c>timestamp_granularities[]</c> field, <c>language</c> only when set, and the
/// file part with an <c>audio/mp4</c> Content-Type.
/// </summary>
public sealed class Transcriber
{
    private readonly HttpClient _http;

    /// <summary>verbose_json file part content type, matching the Swift app's "audio/mp4".</summary>
    public const string FileContentType = "audio/mp4";

    /// <summary>The only OpenAI model that returns per-segment timestamps.</summary>
    public const string TimestampModel = "whisper-1";

    /// <summary>Chunks smaller than this are treated as empty and skipped (Swift: 256 bytes).</summary>
    public const int MinChunkBytes = 256;

    public Transcriber(HttpClient http)
    {
        _http = http;
    }

    /// <summary>
    /// True if this segment is a whisper silence-hallucination and must be dropped:
    /// <c>no_speech_prob &gt; 0.6 &amp;&amp; avg_logprob &lt; -1.0</c>. Pure; unit-tested.
    /// Absent probabilities default to 0.0 (so the filter never fires on them), matching the
    /// Python <c>getattr(..., 0.0) or 0.0</c> and the Swift <c>?? 0.0</c>.
    /// </summary>
    public static bool IsSilenceHallucination(WhisperSegment s)
    {
        var nsp = s.NoSpeechProb ?? 0.0;
        var alp = s.AvgLogprob ?? 0.0;
        return nsp > 0.6 && alp < -1.0;
    }

    /// <summary>
    /// Build the multipart form for one chunk. Exposed (internal) so a test can assert the exact
    /// field set / ordering / content-types without a live HTTP call.
    /// </summary>
    internal static MultipartFormDataContent BuildForm(byte[] fileBytes, string fileName, string? language)
    {
        // Fixed boundary keeps the request deterministic and testable; the proxy doesn't care
        // about the boundary value, only that it's consistent with the header.
        var boundary = "Boundary-" + Guid.NewGuid().ToString("N");
        var form = new MultipartFormDataContent(boundary);

        form.Add(StringField("whisper-1"), "model");
        form.Add(StringField("verbose_json"), "response_format");
        form.Add(StringField("segment"), "timestamp_granularities[]"); // literal brackets, one field
        if (!string.IsNullOrEmpty(language))
        {
            form.Add(StringField(language), "language");
        }

        var fileContent = new ByteArrayContent(fileBytes);
        fileContent.Headers.ContentType = new MediaTypeHeaderValue(FileContentType);
        form.Add(fileContent, "file", fileName);

        return form;

        static StringContent StringField(string value)
        {
            // No charset on simple fields, matching the hand-built macOS multipart parts.
            var c = new StringContent(value);
            c.Headers.ContentType = null;
            return c;
        }
    }

    /// <summary>
    /// One chunk → whisper-1 verbose_json. Throws on non-2xx (the caller continues to the next
    /// chunk, best-effort). Port of Swift <c>transcribeChunk</c>.
    /// </summary>
    public async Task<VerboseTranscription> TranscribeChunkAsync(
        OpenAIConfig config, byte[] fileBytes, string fileName, string? language,
        CancellationToken ct = default)
    {
        using var req = new HttpRequestMessage(HttpMethod.Post,
            CombineUri(config.BaseUrl, "audio/transcriptions"));
        req.Headers.TryAddWithoutValidation(config.AuthName, config.AuthValue);
        req.Content = BuildForm(fileBytes, fileName, language);

        using var resp = await _http.SendAsync(req, ct).ConfigureAwait(false);
        var body = await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
        if (!resp.IsSuccessStatusCode)
        {
            var snippet = body.Length > 400 ? body[..400] : body;
            throw new HttpRequestException($"HTTP {(int)resp.StatusCode}: {snippet}");
        }

        var parsed = JsonSerializer.Deserialize<VerboseTranscription>(body)
                     ?? new VerboseTranscription();
        return parsed;
    }

    /// <summary>
    /// Result of transcribing one track: its kept segments plus the next global idx so the
    /// caller keeps a single input-order counter (mic first, then system) for the merge tiebreak.
    /// </summary>
    public readonly record struct TrackResult(IReadOnlyList<Segment> Segments, int NextIdx);

    /// <summary>
    /// Port of meetrec.py <c>transcribe_track_whisper</c> / Swift <c>transcribeTrack</c>.
    /// Per-chunk failures CONTINUE (best-effort partial transcript), logged via
    /// <paramref name="log"/>. Drops empty text and silence-hallucinations, applies the chunk
    /// offset + baseOffset to globalize timestamps, clamps end ≥ start, and assigns a global,
    /// monotonically increasing idx.
    /// </summary>
    public async Task<TrackResult> TranscribeTrackAsync(
        OpenAIConfig config,
        IReadOnlyList<AudioChunk> chunks,
        double baseOffset,
        string label,
        Source source,
        string? language,
        int startIdx,
        Action<string>? log = null,
        CancellationToken ct = default)
    {
        var segs = new List<Segment>();
        var idx = startIdx;

        for (var i = 0; i < chunks.Count; i++)
        {
            var chunk = chunks[i];
            long size;
            try { size = new FileInfo(chunk.Path).Length; }
            catch { size = 0; }
            if (size < MinChunkBytes)
            {
                log?.Invoke($"  skip {Path.GetFileName(chunk.Path)} (empty)");
                continue;
            }

            log?.Invoke($"Transcribing {SourceName(source)} chunk {i + 1}/{chunks.Count}…");

            VerboseTranscription resp;
            try
            {
                var bytes = await File.ReadAllBytesAsync(chunk.Path, ct).ConfigureAwait(false);
                resp = await TranscribeChunkAsync(config, bytes, Path.GetFileName(chunk.Path),
                    language, ct).ConfigureAwait(false);
            }
            catch (Exception e)
            {
                log?.Invoke($"  {SourceName(source)} chunk {i + 1} failed: {e.Message}");
                continue;
            }

            var off = baseOffset + chunk.Offset;
            foreach (var s in resp.Segments ?? new List<WhisperSegment>())
            {
                var txt = (s.Text ?? "").Trim();
                if (txt.Length == 0) continue;
                if (IsSilenceHallucination(s)) continue;
                var st = s.Start + off;
                var en = Math.Max(s.End + off, st);
                segs.Add(new Segment(st, en, label, txt, source, idx));
                idx++;
            }
        }

        return new TrackResult(segs, idx);
    }

    private static string SourceName(Source s) => s == Source.Mic ? "mic" : "system";

    /// <summary>
    /// Join base + relative, preserving the base path (e.g. ".../v1/audio/transcriptions").
    /// new Uri(base, "audio/...") would drop "/v1"; appending segments avoids that.
    /// </summary>
    private static Uri CombineUri(Uri baseUrl, string relative)
    {
        var b = baseUrl.AbsoluteUri.TrimEnd('/');
        return new Uri($"{b}/{relative}");
    }
}
