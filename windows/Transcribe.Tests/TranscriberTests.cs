using System.Text;
using System.Text.Json;
using Transcribe.Core;
using Xunit;

namespace Transcribe.Tests;

public class TranscriberTests
{
    // --- silence-hallucination filter: no_speech_prob > 0.6 && avg_logprob < -1.0 ---
    [Theory]
    [InlineData(0.7, -1.5, true)]   // both conditions met → dropped
    [InlineData(0.61, -1.01, true)] // just over the thresholds
    [InlineData(0.6, -1.5, false)]  // nsp not strictly > 0.6
    [InlineData(0.7, -1.0, false)]  // alp not strictly < -1.0
    [InlineData(0.7, -0.5, false)]  // high nsp, fine logprob → speech
    [InlineData(0.1, -2.0, false)]  // low nsp → speech even with bad logprob
    public void SilenceFilter(double nsp, double alp, bool dropped)
    {
        var s = new WhisperSegment { NoSpeechProb = nsp, AvgLogprob = alp, Text = "x" };
        Assert.Equal(dropped, Transcriber.IsSilenceHallucination(s));
    }

    [Fact]
    public void SilenceFilter_MissingProbsDefaultToZero_NeverDrops()
    {
        // Absent probabilities → 0.0 each → never silence (matches Python getattr(...,0.0)).
        var s = new WhisperSegment { Text = "x" };
        Assert.False(Transcriber.IsSilenceHallucination(s));
    }

    // --- verbose_json parsing ---
    [Fact]
    public void VerboseJson_Parses()
    {
        const string json = """
        {
          "language": "spanish",
          "duration": 12.34,
          "text": "hola mundo",
          "segments": [
            {"start": 0.0, "end": 1.5, "text": "hola", "avg_logprob": -0.3, "no_speech_prob": 0.01},
            {"start": 1.5, "end": 2.0, "text": "mundo", "avg_logprob": -0.4, "no_speech_prob": 0.02}
          ]
        }
        """;
        var v = JsonSerializer.Deserialize<VerboseTranscription>(json);
        Assert.NotNull(v);
        Assert.Equal("spanish", v!.Language);
        Assert.Equal(12.34, v.Duration);
        Assert.Equal(2, v.Segments!.Count);
        Assert.Equal("hola", v.Segments[0].Text);
        Assert.Equal(0.0, v.Segments[0].Start);
        Assert.Equal(1.5, v.Segments[0].End);
        Assert.Equal(-0.3, v.Segments[0].AvgLogprob);
        Assert.Equal(0.01, v.Segments[0].NoSpeechProb);
    }

    [Fact]
    public void VerboseJson_ToleratesMissingOptionalFields()
    {
        // No avg_logprob / no_speech_prob / text on a segment, no top-level text/duration.
        const string json = """
        {"segments":[{"start":0.0,"end":1.0}]}
        """;
        var v = JsonSerializer.Deserialize<VerboseTranscription>(json);
        Assert.NotNull(v);
        Assert.Null(v!.Text);
        Assert.Single(v.Segments!);
        Assert.Null(v.Segments![0].Text);
        Assert.Null(v.Segments[0].AvgLogprob);
        Assert.Null(v.Segments[0].NoSpeechProb);
    }

    [Fact]
    public void VerboseJson_EmptySegments()
    {
        var v = JsonSerializer.Deserialize<VerboseTranscription>("{\"segments\":[]}");
        Assert.NotNull(v);
        Assert.Empty(v!.Segments!);
    }

    // --- multipart contract: exact field set, names, content types ---
    [Fact]
    public async Task Multipart_HasExactFields_WithLanguage()
    {
        using var form = Transcriber.BuildForm(Encoding.UTF8.GetBytes("FAKEAUDIO"), "mic_chunk_000.m4a", "es");
        var (fields, file) = await ReadForm(form);

        Assert.Equal("whisper-1", fields["model"]);
        Assert.Equal("verbose_json", fields["response_format"]);
        Assert.Equal("segment", fields["timestamp_granularities[]"]); // literal brackets
        Assert.Equal("es", fields["language"]);
        Assert.Equal("file", file.Name);
        Assert.Equal("mic_chunk_000.m4a", file.FileName);
        Assert.Equal("audio/mp4", file.ContentType);
        Assert.Equal("FAKEAUDIO", file.Body);
    }

    [Fact]
    public async Task Multipart_OmitsLanguageWhenNullOrEmpty()
    {
        using var formNull = Transcriber.BuildForm(new byte[] { 1, 2, 3 }, "c.m4a", null);
        var (fieldsNull, _) = await ReadForm(formNull);
        Assert.False(fieldsNull.ContainsKey("language"));

        using var formEmpty = Transcriber.BuildForm(new byte[] { 1, 2, 3 }, "c.m4a", "");
        var (fieldsEmpty, _) = await ReadForm(formEmpty);
        Assert.False(fieldsEmpty.ContainsKey("language"));
    }

    [Fact]
    public void Multipart_ContentTypeHeaderIsMultipart()
    {
        using var form = Transcriber.BuildForm(new byte[] { 9 }, "c.m4a", "en");
        var ct = form.Headers.ContentType!;
        Assert.Equal("multipart/form-data", ct.MediaType);
        Assert.Contains(ct.Parameters, p => p.Name == "boundary");
    }

    // --- helper: read a MultipartFormDataContent back into fields + the file part ---
    private record FilePart(string Name, string FileName, string? ContentType, string Body);

    private static async Task<(Dictionary<string, string> fields, FilePart file)> ReadForm(
        MultipartFormDataContent form)
    {
        var fields = new Dictionary<string, string>();
        FilePart? file = null;
        foreach (var part in form)
        {
            var cd = part.Headers.ContentDisposition!;
            var name = cd.Name!.Trim('"');
            if (cd.FileName != null)
            {
                var body = await part.ReadAsStringAsync();
                file = new FilePart(name, cd.FileName.Trim('"'),
                    part.Headers.ContentType?.MediaType, body);
            }
            else
            {
                fields[name] = await part.ReadAsStringAsync();
            }
        }
        Assert.NotNull(file);
        return (fields, file!);
    }
}
