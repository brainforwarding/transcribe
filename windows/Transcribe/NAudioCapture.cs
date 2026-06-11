using System.Diagnostics;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using Transcribe.Core;

namespace Transcribe.App;

/// <summary>
/// Two-track live capture with NAudio. Mic (always) via WASAPI <see cref="WasapiCapture"/> on the
/// chosen (or default) input device; system audio (Meeting mode ONLY) via
/// <see cref="WasapiLoopbackCapture"/> on the default render device. In "Just me" mode the
/// loopback capture is never constructed — no extra device, no extra permission — matching the
/// macOS CaptureController which skips ScreenCaptureKit entirely when micOnly.
///
/// Each track is written to its own WAV at its native capture format (the segmenter later
/// downmixes + resamples to 16 kHz mono). The mic offset is derived from the wall-clock delta
/// between each track's first data callback (the Windows analog of the macOS first-buffer PTS
/// alignment): how long after the system track the mic track started producing audio.
/// </summary>
public sealed class NAudioCapture : IAudioCapture
{
    private readonly string _outDir;
    private readonly string? _micDeviceId;
    private readonly bool _meetingMode;

    private readonly string _micPath;
    private readonly string _systemPath;

    private WasapiCapture? _mic;
    private WasapiLoopbackCapture? _loopback;
    private WaveFileWriter? _micWriter;
    private WaveFileWriter? _loopWriter;

    private readonly Stopwatch _clock = new();
    private double? _systemFirstSeconds;
    private double? _micFirstSeconds;
    private readonly object _gate = new();

    public Action<string>? OnLog { get; set; }

    /// <param name="meetingMode">true = Meeting (mic + loopback); false = "Just me" (mic only).</param>
    public NAudioCapture(string outDir, string? micDeviceId, bool meetingMode)
    {
        _outDir = outDir;
        _micDeviceId = micDeviceId;
        _meetingMode = meetingMode;
        Directory.CreateDirectory(outDir);
        _micPath = Path.Combine(outDir, "mic.wav");
        _systemPath = Path.Combine(outDir, "system.wav");
    }

    public void Start()
    {
        using var en = new MMDeviceEnumerator();

        // --- mic (always) ---
        MMDevice micDevice;
        if (_micDeviceId != null)
        {
            try { micDevice = en.GetDevice(_micDeviceId); }
            catch
            {
                OnLog?.Invoke($"mic '{_micDeviceId}' not found — using default input.");
                micDevice = en.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Communications);
            }
        }
        else
        {
            micDevice = en.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Communications);
        }

        _mic = new WasapiCapture(micDevice);
        _micWriter = new WaveFileWriter(_micPath, _mic.WaveFormat);
        _mic.DataAvailable += (_, e) =>
        {
            lock (_gate)
            {
                _micFirstSeconds ??= _clock.Elapsed.TotalSeconds;
                _micWriter?.Write(e.Buffer, 0, e.BytesRecorded);
            }
        };
        _mic.RecordingStopped += (_, e) => OnStopped("mic", e);

        // --- system loopback (Meeting mode ONLY) ---
        if (_meetingMode)
        {
            _loopback = new WasapiLoopbackCapture(); // default render device
            _loopWriter = new WaveFileWriter(_systemPath, _loopback.WaveFormat);
            _loopback.DataAvailable += (_, e) =>
            {
                lock (_gate)
                {
                    _systemFirstSeconds ??= _clock.Elapsed.TotalSeconds;
                    _loopWriter?.Write(e.Buffer, 0, e.BytesRecorded);
                }
            };
            _loopback.RecordingStopped += (_, e) => OnStopped("system", e);
        }

        // Start the clock, then both captures. The first-callback timestamps give the offset.
        _clock.Restart();
        _loopback?.StartRecording(); // start system first so the mic offset is ≥ 0, like macOS
        _mic.StartRecording();
    }

    public CaptureResult Stop()
    {
        try { _mic?.StopRecording(); } catch { /* ignore */ }
        try { _loopback?.StopRecording(); } catch { /* ignore */ }

        // Give the RecordingStopped callbacks a moment to flush + dispose the writers.
        var deadline = DateTime.UtcNow.AddSeconds(5);
        while (DateTime.UtcNow < deadline && (_micWriter != null || _loopWriter != null))
        {
            Thread.Sleep(20);
        }
        FlushAndDispose();

        double offset = 0.0;
        lock (_gate)
        {
            if (_meetingMode && _systemFirstSeconds is { } sys && _micFirstSeconds is { } mic)
            {
                offset = Math.Max(0.0, mic - sys);
            }
        }

        return new CaptureResult
        {
            MicWavPath = _micPath,
            SystemWavPath = _meetingMode ? _systemPath : null,
            MicOffset = offset,
        };
    }

    private void OnStopped(string which, StoppedEventArgs e)
    {
        if (e.Exception != null) OnLog?.Invoke($"{which} recording stopped: {e.Exception.Message}");
        lock (_gate)
        {
            if (which == "mic") { _micWriter?.Dispose(); _micWriter = null; }
            else { _loopWriter?.Dispose(); _loopWriter = null; }
        }
    }

    private void FlushAndDispose()
    {
        lock (_gate)
        {
            try { _micWriter?.Dispose(); } catch { } _micWriter = null;
            try { _loopWriter?.Dispose(); } catch { } _loopWriter = null;
        }
    }

    public void Dispose()
    {
        FlushAndDispose();
        _mic?.Dispose();
        _loopback?.Dispose();
    }
}
