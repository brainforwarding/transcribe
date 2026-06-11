using Transcribe.Core;

namespace Transcribe.App;

/// <summary>
/// Orchestrates one record→stop→transcribe→write cycle. Direct behavioral port of the macOS
/// AppModel start/stopRecording: capture both tracks, then on stop start transcription in the
/// background FIRST (so the name prompt never blocks it), prompt for an optional title on the
/// UI thread, then write <c>&lt;stem&gt;.md</c> with collision-safe naming. On success the work
/// dir is removed (raw audio stashed under audio/ if KeepAudio); on failure it is moved to
/// _unfinished/&lt;stamp&gt; so nothing is lost.
/// </summary>
public sealed class RecordingController
{
    private readonly AppSettings _settings;
    private readonly Pipeline _pipeline;

    private IAudioCapture? _capture;
    private string? _stamp;
    private string? _workDir;
    private bool _wasMicOnly;

    public Action<string>? OnLog { get; set; }

    public RecordingController(AppSettings settings, Pipeline pipeline)
    {
        _settings = settings;
        _pipeline = pipeline;
    }

    /// <summary>Factory hook so tests / the app can inject a capture implementation.</summary>
    public Func<string, string?, bool, IAudioCapture> CaptureFactory { get; set; } =
        (outDir, micId, meeting) => new NAudioCapture(outDir, micId, meeting);

    public string SaveFolder => _settings.SaveFolder;

    public static string IsoStamp(DateTime now) => now.ToString("yyyy-MM-dd_HH-mm-ss");

    /// <summary>Human title for an untitled recording: "2026-06-11 · 09:30". Port of humanTitle.</summary>
    public static string HumanTitle(string stamp)
    {
        var parts = stamp.Split('_');
        if (parts.Length != 2) return stamp;
        var time = parts[1].Replace('-', ':');
        if (time.Length >= 5) time = time[..5]; // HH:mm
        return $"{parts[0]} · {time}";
    }

    public void Start(string? micDeviceId, bool micOnly)
    {
        var stamp = IsoStamp(DateTime.Now);
        var work = Path.Combine(_settings.SaveFolder, ".work", stamp);
        Directory.CreateDirectory(work);
        _stamp = stamp;
        _workDir = work;
        _wasMicOnly = micOnly;

        var cap = CaptureFactory(work, micDeviceId, !micOnly);
        cap.OnLog = OnLog;
        _capture = cap;
        cap.Start();
    }

    public sealed record StopOutcome(bool Success, string? TranscriptPath, bool HadSpeech, string Status);

    /// <summary>
    /// Stop capture, transcribe (background), prompt for a title (UI), write the file.
    /// <paramref name="promptForTitle"/> is invoked on the UI thread while transcription runs;
    /// it returns the chosen title or null (skip). <paramref name="config"/> carries the token.
    /// </summary>
    public async Task<StopOutcome> StopAndTranscribeAsync(
        OpenAIConfig config, string? language, Func<string?> promptForTitle,
        CancellationToken ct = default)
    {
        if (_capture is null || _stamp is null || _workDir is null)
            return new StopOutcome(false, null, false, "Nothing was recording.");

        var stamp = _stamp;
        var work = _workDir;
        var wasMicOnly = _wasMicOnly;

        CaptureResult result;
        try
        {
            result = _capture.Stop();
        }
        finally
        {
            _capture.Dispose();
            _capture = null;
        }

        // Transcription starts immediately, off the UI thread…
        var pipelineTask = Task.Run(() => _pipeline.TranscribeSessionBodyAsync(
            config,
            result.MicWavPath,
            result.SystemWavPath,
            work,
            language,
            result.MicOffset,
            labelSpeakers: !wasMicOnly,
            includeSummary: _settings.IncludeSummary,
            log: OnLog,
            ct: ct), ct);

        // …while the optional title prompt runs on the UI thread.
        var userTitle = promptForTitle();

        try
        {
            var body = await pipelineTask.ConfigureAwait(false);

            var stem = Naming.TranscriptStem(stamp, userTitle);
            Directory.CreateDirectory(_settings.SaveFolder);
            var transcriptPath = Naming.AvailableTranscriptPath(_settings.SaveFolder, stem);

            var title = userTitle ?? HumanTitle(stamp);
            var md = $"# {title}\n\n" + body.Body;
            await File.WriteAllTextAsync(transcriptPath, md, new System.Text.UTF8Encoding(false), ct)
                .ConfigureAwait(false);

            FinishWorkDir(work, stamp, success: true);
            var status = body.HadSpeech ? "" : "No speech detected (silent recording?).";
            return new StopOutcome(true, transcriptPath, body.HadSpeech, status);
        }
        catch (Exception e)
        {
            FinishWorkDir(work, stamp, success: false);
            return new StopOutcome(false, null, false,
                $"Transcription failed — audio kept in _unfinished/ to retry. ({e.Message})");
        }
    }

    /// <summary>On success: drop the work dir (stash raw tracks under audio/ if KeepAudio). On
    /// failure: move the work dir to _unfinished/&lt;stamp&gt;. Port of finishWorkDir.</summary>
    private void FinishWorkDir(string work, string stamp, bool success)
    {
        if (!success)
        {
            try
            {
                var dest = Path.Combine(_settings.SaveFolder, "_unfinished", stamp);
                Directory.CreateDirectory(Path.GetDirectoryName(dest)!);
                if (Directory.Exists(dest)) Directory.Delete(dest, recursive: true);
                Directory.Move(work, dest);
            }
            catch { /* best effort */ }
            return;
        }

        try
        {
            if (_settings.KeepAudio)
            {
                var dest = Path.Combine(_settings.SaveFolder, "audio", stamp);
                Directory.CreateDirectory(dest);
                foreach (var name in new[] { "system.wav", "mic.wav" })
                {
                    var src = Path.Combine(work, name);
                    if (!File.Exists(src)) continue;
                    var dst = Path.Combine(dest, name);
                    if (File.Exists(dst)) File.Delete(dst);
                    File.Move(src, dst);
                }
            }
            Directory.Delete(work, recursive: true);

            var workParent = Path.Combine(_settings.SaveFolder, ".work");
            if (Directory.Exists(workParent) &&
                Directory.GetFileSystemEntries(workParent).Length == 0)
            {
                Directory.Delete(workParent);
            }
        }
        catch { /* best effort */ }
    }
}
