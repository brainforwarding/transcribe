using NAudio.MediaFoundation;
using NAudio.Wave;
using Transcribe.Core;

namespace Transcribe.App;

/// <summary>
/// NAudio implementation of <see cref="IAudioSegmenter"/>: downmix + resample one captured WAV
/// track to mono 16 kHz 16-bit PCM, split into ≤chunkSeconds WAV chunks. Each chunk is a
/// standalone WAV starting at 0; its <see cref="AudioChunk.Offset"/> (a multiple of chunkSeconds
/// on the output timeline) globalizes the per-chunk whisper timestamps — exactly the contract the
/// macOS Segmenter implements (it emits m4a; we emit 16 kHz mono WAV, which whisper-1 accepts and
/// which keeps each ~8-minute chunk well under the 25 MiB limit at ~32 KB/s).
///
/// Resampling uses MediaFoundationResampler (per the SPEC). It is created lazily/disposed per
/// track. The output is forced to 16 kHz mono 16-bit PCM so chunk sizes are predictable.
/// </summary>
public sealed class NAudioSegmenter : IAudioSegmenter
{
    private const int OutSampleRate = 16_000;
    private const int OutChannels = 1;
    private const int OutBitsPerSample = 16;

    public Action<string>? OnLog { get; set; }

    public IReadOnlyList<AudioChunk> SegmentTrack(string srcPath, string outDir, string prefix,
        double chunkSeconds = IAudioSegmenter.MaxChunkSeconds)
    {
        if (!File.Exists(srcPath)) return Array.Empty<AudioChunk>();
        try
        {
            // A WAV with only a header (~44 bytes) and no samples is "empty".
            if (new FileInfo(srcPath).Length <= 1024) return Array.Empty<AudioChunk>();
        }
        catch
        {
            return Array.Empty<AudioChunk>();
        }

        Directory.CreateDirectory(outDir);

        // Media Foundation must be initialized before MediaFoundationResampler is used.
        // (The ctor does this too in NAudio 2.x; calling it explicitly is idempotent and safe.)
        MediaFoundationApi.Startup();

        var chunks = new List<AudioChunk>();
        var outFormat = new WaveFormat(OutSampleRate, OutBitsPerSample, OutChannels);
        var framesPerChunk = (long)(chunkSeconds * OutSampleRate); // samples per chunk per channel
        var bytesPerFrame = OutChannels * (OutBitsPerSample / 8);  // = 2 for mono 16-bit

        try
        {
            using var reader = new AudioFileReader(srcPath); // float32; AudioFileReader reads WAV
            // MediaFoundationResampler downmixes + resamples to the requested output format.
            using var resampler = new MediaFoundationResampler(reader, outFormat)
            {
                ResamplerQuality = 60,
            };

            WaveFileWriter? writer = null;
            long framesInChunk = 0;
            var buffer = new byte[outFormat.AverageBytesPerSecond]; // ~1s blocks

            try
            {
                int read;
                while ((read = resampler.Read(buffer, 0, buffer.Length)) > 0)
                {
                    var offset = 0;
                    while (offset < read)
                    {
                        if (writer == null || framesInChunk >= framesPerChunk)
                        {
                            writer?.Dispose();
                            var path = Path.Combine(outDir, $"{prefix}_chunk_{chunks.Count:D3}.wav");
                            TryDelete(path);
                            writer = new WaveFileWriter(path, outFormat);
                            chunks.Add(new AudioChunk(path, chunks.Count * chunkSeconds));
                            framesInChunk = 0;
                        }

                        var remainingInChunk = (framesPerChunk - framesInChunk) * bytesPerFrame;
                        var available = read - offset;
                        var toWrite = (int)Math.Min(available, remainingInChunk);
                        // Never split a frame across the chunk boundary.
                        toWrite -= toWrite % bytesPerFrame;
                        if (toWrite <= 0)
                        {
                            // Force a new chunk on the next loop iteration.
                            framesInChunk = framesPerChunk;
                            continue;
                        }

                        writer.Write(buffer, offset, toWrite);
                        offset += toWrite;
                        framesInChunk += toWrite / bytesPerFrame;
                    }
                }
            }
            finally
            {
                writer?.Dispose();
            }
        }
        catch (Exception e)
        {
            OnLog?.Invoke($"segment {prefix} failed: {e.Message}");
            return chunks; // whatever completed; pipeline is best-effort
        }

        return chunks;
    }

    private static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); } catch { /* ignore */ }
    }
}
