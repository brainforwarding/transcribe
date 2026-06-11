using Transcribe.Core;
using Xunit;

namespace Transcribe.Tests;

/// <summary>
/// Ports Selftest.swift namingSelftest (slug, stem, collision suffix) plus extras.
/// </summary>
public class NamingTests
{
    // --- slugify (Selftest naming case "s.*") ---
    [Fact] public void Slug_Basic() => Assert.Equal("weekly-sync", Naming.Slugify("Weekly sync"));

    [Fact]
    public void Slug_AccentsFolded() =>
        Assert.Equal("reunion-de-diseno-cafe", Naming.Slugify("Reunión de diseño — café"));

    [Fact]
    public void Slug_PunctuationCollapsed() =>
        Assert.Equal("hello-world", Naming.Slugify("  Hello,,,   World!! "));

    [Fact] public void Slug_Digits() => Assert.Equal("q3-2026-planning", Naming.Slugify("Q3 2026 planning"));

    [Fact] public void Slug_NothingLeft() => Assert.Equal("", Naming.Slugify("¿¿??"));

    [Fact]
    public void Slug_MaxLenHardCap() =>
        Assert.Equal("aaaaaaaaaa", Naming.Slugify(new string('a', 100), maxLength: 10));

    [Fact]
    public void Slug_MaxLenDropsTrailingHyphen() =>
        Assert.Equal("aaa", Naming.Slugify("aaa bbb", maxLength: 4));

    // --- extra slug edge cases ---
    [Fact] public void Slug_LeadingTrailingSpecials() => Assert.Equal("hi", Naming.Slugify("---hi---"));

    [Fact] public void Slug_Empty() => Assert.Equal("", Naming.Slugify(""));

    [Fact]
    public void Slug_MixedCaseAndUnderscores() =>
        Assert.Equal("my-file-name", Naming.Slugify("My_File__Name"));

    // --- transcriptStem (Selftest naming "n.*") ---
    private const string Stamp = "2026-06-11_09-30-00";

    [Fact]
    public void Stem_Titled() =>
        Assert.Equal("2026-06-11-voice-note", Naming.TranscriptStem(Stamp, "Voice note"));

    [Fact]
    public void Stem_UntitledNull() => Assert.Equal(Stamp, Naming.TranscriptStem(Stamp, null));

    [Fact]
    public void Stem_UnusableTitleFallsBackToStamp() =>
        Assert.Equal(Stamp, Naming.TranscriptStem(Stamp, "!!!"));

    // --- availableTranscriptName (Selftest naming "n.free" / "n.collision") ---
    [Fact]
    public void Available_FreeName()
    {
        var taken = new HashSet<string> { "a.md", "a-2.md" };
        Assert.Equal("b.md", Naming.AvailableTranscriptName("b", taken.Contains));
    }

    [Fact]
    public void Available_CollisionWalksToNextFree()
    {
        var taken = new HashSet<string> { "a.md", "a-2.md" };
        Assert.Equal("a-3.md", Naming.AvailableTranscriptName("a", taken.Contains));
    }

    [Fact]
    public void Available_FirstCollisionUsesDashTwo()
    {
        var taken = new HashSet<string> { "a.md" };
        Assert.Equal("a-2.md", Naming.AvailableTranscriptName("a", taken.Contains));
    }
}
