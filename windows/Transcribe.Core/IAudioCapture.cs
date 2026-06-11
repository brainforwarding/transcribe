namespace Transcribe.Core;

/// <summary>
/// One ≤chunkSeconds slice of a track, already downmixed to mono 16 kHz and written to disk
/// (WAV or m4a). <see cref="Offset"/> is the chunk's start time (seconds) on the source
/// timeline — a multiple of the chunk length — used to globalize whisper's per-chunk
/// timestamps. Mirrors the Swift <c>AudioChunk</c>.
/// </summary>
public readonly record struct AudioChunk(string Path, double Offset);

/// <summary>
/// Segments one captured track into chunks under the Whisper size limit. The concrete
/// implementation (NAudio MediaFoundationResampler → 16 kHz mono WAV, split by time) lives in
/// the app project so the Core stays portable. Kept as an interface purely so the pipeline is
/// unit-testable with a fake.
/// </summary>
public interface IAudioSegmenter
{
    /// <summary>
    /// Downmix + resample <paramref name="srcPath"/> to mono 16 kHz and split into
    /// ≤<paramref name="chunkSeconds"/> chunks written to <paramref name="outDir"/> with the
    /// given <paramref name="prefix"/>. Returns the chunks in time order. Returns an empty list
    /// if the source is missing or effectively empty.
    /// </summary>
    IReadOnlyList<AudioChunk> SegmentTrack(string srcPath, string outDir, string prefix, double chunkSeconds = MaxChunkSeconds);

    /// <summary>
    /// WAV 16 kHz mono 16-bit ≈ 32 KB/s. The Whisper limit is 25 MiB; 8 minutes ≈ 15 MiB,
    /// comfortably under. Mirrors the SPEC's ≤ 8 minute cap.
    /// </summary>
    public const double MaxChunkSeconds = 8 * 60;
}

/// <summary>
/// Result of a two-track capture session. <see cref="SystemWavPath"/> is null in "Just me"
/// (mic-only) mode — loopback is never opened. <see cref="MicOffset"/> is how many seconds the
/// mic track started AFTER the system track, used to align the two on one timeline (mirrors the
/// macOS CaptureController.Result.micOffset; 0 when there is no system track).
/// </summary>
public sealed class CaptureResult
{
    public required string MicWavPath { get; init; }
    public string? SystemWavPath { get; init; }
    public double MicOffset { get; init; }
}

/// <summary>
/// Live audio capture seam. Meeting mode records both mic and WASAPI loopback; "Just me"
/// records only the mic and leaves <see cref="CaptureResult.SystemWavPath"/> null. Implemented
/// with NAudio in the app project; the pipeline never references it directly (it consumes the
/// resulting WAV paths), but the interface documents the contract and keeps the app testable.
/// </summary>
public interface IAudioCapture : IDisposable
{
    /// <summary>Begin capturing. Throws if a device can't be opened.</summary>
    void Start();

    /// <summary>Stop capturing, finalize the WAV files, and return their paths + offset.</summary>
    CaptureResult Stop();

    /// <summary>Optional diagnostics sink (stderr/console/UI).</summary>
    Action<string>? OnLog { get; set; }
}
