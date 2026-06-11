using Transcribe.Core;
using Xunit;

namespace Transcribe.Tests;

/// <summary>
/// Ports the Selftest render + banker's-rounding cases, plus both render modes end to end.
/// </summary>
public class RenderTests
{
    private static Segment Seg(double s, double e, string label, string text, Source source, int idx = 0)
        => new(s, e, label, text, source, idx);

    // --- 7. banker's rounding (Selftest case 7) ---
    [Fact]
    public void Mmss_BasicMinutesSeconds() => Assert.Equal("02:05", Render.Mmss(125.0));

    [Fact]
    public void Mmss_HalfToEven_RoundsDown() => Assert.Equal("00:30", Render.Mmss(30.5)); // 30 is even

    [Fact]
    public void Mmss_HalfToEven_RoundsUp() => Assert.Equal("00:32", Render.Mmss(31.5)); // 32 is even

    [Theory]
    [InlineData(0.0, "00:00")]
    [InlineData(-5.0, "00:00")]      // clamp to >= 0
    [InlineData(0.4, "00:00")]
    [InlineData(0.6, "00:01")]
    [InlineData(59.5, "01:00")]      // 60 is even → rounds up, carries to minute
    [InlineData(60.0, "01:00")]
    [InlineData(89.5, "01:30")]      // 90 even
    [InlineData(90.5, "01:30")]      // 90 even → rounds down
    [InlineData(3599.0, "59:59")]
    [InlineData(3600.0, "60:00")]    // no hours, minutes can exceed 60
    public void Mmss_Table(double t, string expected) => Assert.Equal(expected, Render.Mmss(t));

    // --- render with / without timestamps (Selftest case 7) ---
    [Fact]
    public void RenderConversation_WithTimestamps()
    {
        var s = Render.RenderConversation(new[] { Seg(0, 1, "You", "first", Source.Mic) }, timestamps: true);
        Assert.Equal("[00:00] **You:** first", s);
    }

    [Fact]
    public void RenderConversation_WithoutTimestamps()
    {
        var s = Render.RenderConversation(new[] { Seg(5, 6, "Them", "x", Source.System) }, timestamps: false);
        Assert.Equal("**Them:** x", s);
    }

    // --- Meeting mode: blocks separated by a blank line, You/Them labels ---
    [Fact]
    public void RenderConversation_MeetingMode_BlankLineSeparated()
    {
        var s = Render.RenderConversation(new[]
        {
            Seg(0, 2, "You", "hi", Source.Mic, 0),
            Seg(65, 70, "Them", "hello", Source.System, 1),
        }, timestamps: true);
        Assert.Equal("[00:00] **You:** hi\n\n[01:05] **Them:** hello", s);
    }

    // --- 8. mic-only render: plain paragraphs, no labels, no timestamps (Selftest case 8) ---
    [Fact]
    public void RenderPlain_TwoThoughts()
    {
        var s = Render.RenderPlain(new[]
        {
            Seg(0, 1, "You", "first thought.", Source.Mic, 0),
            Seg(3, 4, "You", "second thought.", Source.Mic, 1),
        });
        Assert.Equal("first thought.\n\nsecond thought.", s);
    }

    [Fact]
    public void RenderPlain_Empty() => Assert.Equal("", Render.RenderPlain(Array.Empty<Segment>()));

    // --- appendix (verbatim per-track) ---
    [Fact]
    public void RenderAppendix_TwoTracks()
    {
        var s = Render.RenderAppendix(new (string, IReadOnlyList<Segment>)[]
        {
            ("You (mic)", new[] { Seg(0, 1, "You", "hey", Source.Mic), Seg(1, 2, "You", "there", Source.Mic) }),
            ("Them (system)", new[] { Seg(0, 1, "Them", "hi", Source.System) }),
        });
        Assert.Equal("### You (mic)\n\nhey there\n\n### Them (system)\n\nhi", s);
    }

    [Fact]
    public void RenderAppendix_EmptyTrackShowsPlaceholder()
    {
        var s = Render.RenderAppendix(new (string, IReadOnlyList<Segment>)[]
        {
            ("You (mic)", Array.Empty<Segment>()),
        });
        Assert.Equal("### You (mic)\n\n_(no speech detected)_", s);
    }
}
