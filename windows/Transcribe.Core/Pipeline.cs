namespace Transcribe.Core;

/// <summary>Everything below the transcript's H1 — mirrors the Swift <c>SessionBody</c>.</summary>
public sealed class SessionBody
{
    /// <summary>Markdown below the H1; always ends with "\n".</summary>
    public required string Body { get; init; }
    public required string Conversation { get; init; }
    public bool HadSpeech { get; init; }
}

/// <summary>Final pipeline result — mirrors the Swift <c>PipelineResult</c>.</summary>
public sealed class PipelineResult
{
    public required string TranscriptPath { get; init; }
    public required string Conversation { get; init; }
    public bool HadSpeech { get; init; }
}

/// <summary>
/// The transcription pipeline: segment each track, transcribe with whisper-1, merge on the
/// shared timeline, render for the chosen mode, optionally summarize, and write the markdown.
/// Direct port of Swift <c>Pipeline.swift</c> (<c>transcribeSessionBody</c> /
/// <c>transcribeSession</c>). Audio segmentation is behind <see cref="IAudioSegmenter"/> so this
/// is fully unit-testable with a fake segmenter + a fake HTTP handler.
/// </summary>
public sealed class Pipeline
{
    private readonly IAudioSegmenter _segmenter;
    private readonly Transcriber _transcriber;
    private readonly Summarizer _summarizer;

    public Pipeline(IAudioSegmenter segmenter, Transcriber transcriber, Summarizer summarizer)
    {
        _segmenter = segmenter;
        _transcriber = transcriber;
        _summarizer = summarizer;
    }

    /// <summary>
    /// Build the body (rendered conversation, plus optional Summary section) without the final
    /// file write — lets the app start transcribing immediately and decide the title/filename
    /// afterwards (the name-on-stop prompt). <paramref name="labelSpeakers"/> = false is mic-only
    /// ("Just me") mode: a single track rendered as plain paragraphs, no You/Them labels, no
    /// timestamps. Port of <c>transcribeSessionBody</c>.
    /// </summary>
    public async Task<SessionBody> TranscribeSessionBodyAsync(
        OpenAIConfig config,
        string? micWavPath,
        string? systemWavPath,
        string chunkDir,
        string? language,
        double micOffset,
        string meLabel = "You",
        string themLabel = "Them",
        bool labelSpeakers = true,
        bool includeSummary = false,
        string summaryModel = "gpt-4o",
        Action<string>? log = null,
        CancellationToken ct = default)
    {
        Directory.CreateDirectory(chunkDir);

        var idx = 0;
        IReadOnlyList<Segment> micSegs = Array.Empty<Segment>();
        IReadOnlyList<Segment> sysSegs = Array.Empty<Segment>();

        // Mic track FIRST — this assigns the lower idx range, so the merge tiebreak is
        // deterministic (mic before system at equal start/end). Order matters for byte-identity.
        if (!string.IsNullOrEmpty(micWavPath) && File.Exists(micWavPath))
        {
            var chunks = _segmenter.SegmentTrack(micWavPath, chunkDir, "mic");
            var r = await _transcriber.TranscribeTrackAsync(
                config, chunks, micOffset, meLabel, Source.Mic, language, idx, log, ct)
                .ConfigureAwait(false);
            micSegs = r.Segments;
            idx = r.NextIdx;
        }

        if (!string.IsNullOrEmpty(systemWavPath) && File.Exists(systemWavPath))
        {
            var chunks = _segmenter.SegmentTrack(systemWavPath, chunkDir, "sys");
            var r = await _transcriber.TranscribeTrackAsync(
                config, chunks, 0.0, themLabel, Source.System, language, idx, log, ct)
                .ConfigureAwait(false);
            sysSegs = r.Segments;
            idx = r.NextIdx;
        }

        var all = new List<Segment>(micSegs.Count + sysSegs.Count);
        all.AddRange(micSegs);
        all.AddRange(sysSegs);

        var blocks = Merge.MergeSegments(all);
        var conversation = labelSpeakers
            ? Render.RenderConversation(blocks, timestamps: true)
            : Render.RenderPlain(blocks);

        string body;
        string? summary = null;
        if (includeSummary && conversation.Length > 0)
        {
            var summaryInput = labelSpeakers
                ? Render.RenderConversation(blocks, timestamps: false)
                : conversation;
            summary = await _summarizer.SummarizeAsync(config, summaryInput, summaryModel, ct)
                .ConfigureAwait(false);
        }

        if (summary != null)
        {
            var heading = labelSpeakers ? "Conversation" : "Transcript";
            body = $"## Summary\n\n{summary}\n\n## {heading}\n\n{conversation}\n";
        }
        else
        {
            body = (conversation.Length == 0 ? "_(no speech detected)_" : conversation) + "\n";
        }

        return new SessionBody
        {
            Body = body,
            Conversation = conversation,
            HadSpeech = blocks.Count > 0,
        };
    }

    /// <summary>
    /// Full path: build the body, prepend <c># &lt;title&gt;\n\n</c>, and write the markdown
    /// to <paramref name="transcriptPath"/>. Port of <c>transcribeSession</c>.
    /// </summary>
    public async Task<PipelineResult> TranscribeSessionAsync(
        OpenAIConfig config,
        string? micWavPath,
        string? systemWavPath,
        string chunkDir,
        string transcriptPath,
        string title,
        string? language,
        double micOffset,
        string meLabel = "You",
        string themLabel = "Them",
        bool labelSpeakers = true,
        bool includeSummary = false,
        string summaryModel = "gpt-4o",
        Action<string>? log = null,
        CancellationToken ct = default)
    {
        var r = await TranscribeSessionBodyAsync(
            config, micWavPath, systemWavPath, chunkDir, language, micOffset,
            meLabel, themLabel, labelSpeakers, includeSummary, summaryModel, log, ct)
            .ConfigureAwait(false);

        var md = $"# {title}\n\n" + r.Body;
        var dir = Path.GetDirectoryName(transcriptPath);
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
        await File.WriteAllTextAsync(transcriptPath, md, new System.Text.UTF8Encoding(false), ct)
            .ConfigureAwait(false);

        return new PipelineResult
        {
            TranscriptPath = transcriptPath,
            Conversation = r.Conversation,
            HadSpeech = r.HadSpeech,
        };
    }
}
