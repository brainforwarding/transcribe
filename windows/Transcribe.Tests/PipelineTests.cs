using System.Net;
using Transcribe.Core;
using Xunit;

namespace Transcribe.Tests;

/// <summary>
/// End-to-end pipeline tests with a fake segmenter (returns one chunk per track) and a fake
/// HTTP handler returning canned verbose_json. These prove the full chain — segment →
/// transcribe → silence-filter → merge → render → write — produces the exact macOS-format
/// output for both modes.
/// </summary>
public class PipelineTests : IDisposable
{
    private readonly string _dir;
    private readonly OpenAIConfig _config =
        new(new Uri("https://transcribe-proxy.quiet-bush-25b1.workers.dev/v1"), "Bearer test-token");

    public PipelineTests()
    {
        _dir = Path.Combine(Path.GetTempPath(), "transcribe-tests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_dir);
    }

    public void Dispose()
    {
        try { Directory.Delete(_dir, recursive: true); } catch { /* best effort */ }
    }

    /// <summary>Fake segmenter: returns exactly one chunk per track, writing a dummy file so
    /// the size check (≥256 bytes) passes.</summary>
    private sealed class FakeSegmenter : IAudioSegmenter
    {
        private readonly string _dir;
        public FakeSegmenter(string dir) { _dir = dir; }

        public IReadOnlyList<AudioChunk> SegmentTrack(string srcPath, string outDir, string prefix,
            double chunkSeconds = IAudioSegmenter.MaxChunkSeconds)
        {
            var path = Path.Combine(outDir, $"{prefix}_chunk_000.m4a");
            File.WriteAllBytes(path, new byte[512]); // ≥ MinChunkBytes
            return new[] { new AudioChunk(path, 0.0) };
        }
    }

    private Pipeline MakePipeline(Func<HttpRequestMessage, Task<HttpResponseMessage>> responder,
        out FakeHttpHandler handler)
        => MakePipeline((req, _) => responder(req), out handler);

    private Pipeline MakePipeline(Func<HttpRequestMessage, string, Task<HttpResponseMessage>> responder,
        out FakeHttpHandler handler)
    {
        handler = new FakeHttpHandler(responder);
        var http = new HttpClient(handler);
        var transcriber = new Transcriber(http);
        var summarizer = new Summarizer(http);
        return new Pipeline(new FakeSegmenter(_dir), transcriber, summarizer);
    }

    private static string Verbose(params (double start, double end, string text)[] segs)
    {
        var items = segs.Select(s =>
            $"{{\"start\":{s.start.ToString(System.Globalization.CultureInfo.InvariantCulture)}," +
            $"\"end\":{s.end.ToString(System.Globalization.CultureInfo.InvariantCulture)}," +
            $"\"text\":\"{s.text}\",\"avg_logprob\":-0.3,\"no_speech_prob\":0.01}}");
        return "{\"segments\":[" + string.Join(",", items) + "]}";
    }

    [Fact]
    public async Task Meeting_TwoTracks_RendersYouThemWithTimestamps()
    {
        var mic = Path.Combine(_dir, "mic.wav"); File.WriteAllBytes(mic, new byte[1024]);
        var sys = Path.Combine(_dir, "system.wav"); File.WriteAllBytes(sys, new byte[1024]);

        var pipeline = MakePipeline((req, body) =>
        {
            // mic chunk filename vs sys chunk filename distinguishes the two calls
            var isMic = body.Contains("mic_chunk_000.m4a");
            var json = isMic
                ? Verbose((0.0, 2.0, "hello there"))
                : Verbose((3.0, 4.0, "good thanks"));
            return Task.FromResult(FakeHttpHandler.Json(HttpStatusCode.OK, json));
        }, out _);

        var body2 = await pipeline.TranscribeSessionBodyAsync(
            _config, mic, sys, _dir, language: "es", micOffset: 0.0,
            labelSpeakers: true, includeSummary: false);

        Assert.Equal("[00:00] **You:** hello there\n\n[00:03] **Them:** good thanks\n", body2.Body);
        Assert.True(body2.HadSpeech);
    }

    [Fact]
    public async Task JustMe_MicOnly_RendersPlainParagraphsNoLabels()
    {
        var mic = Path.Combine(_dir, "mic.wav"); File.WriteAllBytes(mic, new byte[1024]);

        var pipeline = MakePipeline(_ =>
            Task.FromResult(FakeHttpHandler.Json(HttpStatusCode.OK,
                Verbose((0.0, 1.0, "first thought."), (3.0, 4.0, "second thought.")))),
            out var handler);

        var body = await pipeline.TranscribeSessionBodyAsync(
            _config, mic, systemWavPath: null, _dir, language: "es", micOffset: 0.0,
            labelSpeakers: false, includeSummary: false);

        Assert.Equal("first thought.\n\nsecond thought.\n", body.Body);
        // Only the mic track was transcribed — no loopback call.
        Assert.Single(handler.Requests);
    }

    [Fact]
    public async Task SilenceHallucination_IsDroppedInPipeline()
    {
        var mic = Path.Combine(_dir, "mic.wav"); File.WriteAllBytes(mic, new byte[1024]);

        var pipeline = MakePipeline(_ =>
        {
            // Second segment is a silence-hallucination (nsp 0.7, alp -1.5) → must be dropped.
            const string json =
                "{\"segments\":[" +
                "{\"start\":0.0,\"end\":1.0,\"text\":\"real speech\",\"avg_logprob\":-0.3,\"no_speech_prob\":0.01}," +
                "{\"start\":1.1,\"end\":2.0,\"text\":\"you you you\",\"avg_logprob\":-1.5,\"no_speech_prob\":0.7}" +
                "]}";
            return Task.FromResult(FakeHttpHandler.Json(HttpStatusCode.OK, json));
        }, out _);

        var body = await pipeline.TranscribeSessionBodyAsync(
            _config, mic, null, _dir, language: null, micOffset: 0.0, labelSpeakers: false);

        Assert.Equal("real speech\n", body.Body);
    }

    [Fact]
    public async Task NoSpeech_WritesPlaceholder()
    {
        var mic = Path.Combine(_dir, "mic.wav"); File.WriteAllBytes(mic, new byte[1024]);
        var pipeline = MakePipeline(_ =>
            Task.FromResult(FakeHttpHandler.Json(HttpStatusCode.OK, "{\"segments\":[]}")), out _);

        var body = await pipeline.TranscribeSessionBodyAsync(
            _config, mic, null, _dir, language: null, micOffset: 0.0, labelSpeakers: false);

        Assert.Equal("_(no speech detected)_\n", body.Body);
        Assert.False(body.HadSpeech);
    }

    [Fact]
    public async Task PerChunkFailure_Continues_BestEffort()
    {
        var mic = Path.Combine(_dir, "mic.wav"); File.WriteAllBytes(mic, new byte[1024]);
        var sys = Path.Combine(_dir, "system.wav"); File.WriteAllBytes(sys, new byte[1024]);

        var pipeline = MakePipeline((req, body) =>
        {
            if (body.Contains("sys_chunk_000.m4a"))
                // system track 500s — should be swallowed, mic transcript still produced
                return Task.FromResult(FakeHttpHandler.Json(HttpStatusCode.InternalServerError, "boom"));
            return Task.FromResult(FakeHttpHandler.Json(HttpStatusCode.OK, Verbose((0.0, 1.0, "i talked"))));
        }, out _);

        var body2 = await pipeline.TranscribeSessionBodyAsync(
            _config, mic, sys, _dir, language: null, micOffset: 0.0, labelSpeakers: true);

        Assert.Equal("[00:00] **You:** i talked\n", body2.Body);
    }

    [Fact]
    public async Task MicOffset_GlobalizesTimestamps()
    {
        var mic = Path.Combine(_dir, "mic.wav"); File.WriteAllBytes(mic, new byte[1024]);
        var pipeline = MakePipeline(_ =>
            Task.FromResult(FakeHttpHandler.Json(HttpStatusCode.OK, Verbose((0.0, 1.0, "hi")))), out _);

        // Mic started 5s after the (absent) system track baseline → [00:05].
        var body = await pipeline.TranscribeSessionBodyAsync(
            _config, mic, null, _dir, language: null, micOffset: 5.0, labelSpeakers: true);

        Assert.Equal("[00:05] **You:** hi\n", body.Body);
    }

    [Fact]
    public async Task Summary_PrependedWhenEnabled()
    {
        var mic = Path.Combine(_dir, "mic.wav"); File.WriteAllBytes(mic, new byte[1024]);
        var pipeline = MakePipeline(req =>
        {
            if (req.RequestUri!.AbsoluteUri.Contains("chat/completions"))
            {
                const string chat = "{\"choices\":[{\"message\":{\"content\":\"A short summary.\"}}]}";
                return Task.FromResult(FakeHttpHandler.Json(HttpStatusCode.OK, chat));
            }
            return Task.FromResult(FakeHttpHandler.Json(HttpStatusCode.OK, Verbose((0.0, 1.0, "hi there"))));
        }, out _);

        var body = await pipeline.TranscribeSessionBodyAsync(
            _config, mic, null, _dir, language: null, micOffset: 0.0,
            labelSpeakers: false, includeSummary: true);

        Assert.Equal("## Summary\n\nA short summary.\n\n## Transcript\n\nhi there\n", body.Body);
    }

    [Fact]
    public async Task FullSession_WritesFileWithH1Title()
    {
        var mic = Path.Combine(_dir, "mic.wav"); File.WriteAllBytes(mic, new byte[1024]);
        var pipeline = MakePipeline(_ =>
            Task.FromResult(FakeHttpHandler.Json(HttpStatusCode.OK, Verbose((0.0, 1.0, "the note")))), out _);

        var outPath = Path.Combine(_dir, "out.md");
        var result = await pipeline.TranscribeSessionAsync(
            _config, mic, null, _dir, outPath, title: "My note",
            language: null, micOffset: 0.0, labelSpeakers: false);

        var written = await File.ReadAllTextAsync(result.TranscriptPath);
        Assert.Equal("# My note\n\nthe note\n", written);
    }
}
