using System.Text.Json.Serialization;

namespace Transcribe.Core;

/// <summary>
/// whisper-1 verbose_json segment schema. Optionals guarded per the Python/Swift contract:
/// <c>text</c> may be missing/null, <c>avg_logprob</c> / <c>no_speech_prob</c> default to 0.0
/// when absent. Mirrors the Swift <c>WhisperSegment</c>.
/// </summary>
public sealed class WhisperSegment
{
    [JsonPropertyName("start")]
    public double Start { get; set; }

    [JsonPropertyName("end")]
    public double End { get; set; }

    [JsonPropertyName("text")]
    public string? Text { get; set; }

    [JsonPropertyName("avg_logprob")]
    public double? AvgLogprob { get; set; }

    [JsonPropertyName("no_speech_prob")]
    public double? NoSpeechProb { get; set; }
}

/// <summary>
/// The verbose_json envelope. Mirrors the Swift <c>VerboseTranscription</c>.
/// </summary>
public sealed class VerboseTranscription
{
    [JsonPropertyName("language")]
    public string? Language { get; set; }

    [JsonPropertyName("duration")]
    public double? Duration { get; set; }

    [JsonPropertyName("text")]
    public string? Text { get; set; }

    [JsonPropertyName("segments")]
    public List<WhisperSegment>? Segments { get; set; }
}
