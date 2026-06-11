using Transcribe.Core;
using Xunit;

namespace Transcribe.Tests;

/// <summary>
/// Ports the macOS Selftest.swift mergeSelftest cases verbatim, plus the extra ordering /
/// tiebreak / coalesce / You-Them-interleave cases the SPEC calls out. These pin the Windows
/// merge output byte-identical to the macOS app on the same inputs.
/// </summary>
public class MergeTests
{
    private static Segment Seg(double s, double e, string label, string text, Source source, int idx = 0)
        => new(s, e, label, text, source, idx);

    // --- 1. adjacency coalesce + chronology (Selftest case 1) ---
    [Fact]
    public void AdjacencyCoalesceAndChronology()
    {
        var b = Merge.MergeSegments(new[]
        {
            Seg(0.0, 2.0, "You", "hello there", Source.Mic, 0),
            Seg(2.3, 2.9, "You", "how are you", Source.Mic, 1),
            Seg(3.0, 4.0, "Them", "good thanks", Source.System, 2),
            Seg(4.2, 5.0, "You", "great", Source.Mic, 3),
        });

        Assert.Equal(new[] { "You", "Them", "You" }, b.Select(x => x.Label));
        Assert.Equal("hello there how are you", b[0].Text);
        Assert.Equal(3, b.Count);
        Assert.Equal("great", b[2].Text);
    }

    // --- 2. interleave by start across tracks (Selftest case 2) ---
    [Fact]
    public void InterleaveByStartAcrossTracks()
    {
        var b = Merge.MergeSegments(new[]
        {
            Seg(5.0, 6.0, "Them", "second", Source.System, 0),
            Seg(0.5, 1.0, "You", "first", Source.Mic, 1),
            Seg(10.0, 11.0, "You", "third", Source.Mic, 2),
        });
        Assert.Equal(new[] { "first", "second", "third" }, b.Select(x => x.Text));
    }

    // --- 3. gap threshold inclusive (Selftest case 3) ---
    [Fact]
    public void GapTooBigBreaksRun()
    {
        var b = Merge.MergeSegments(new[]
        {
            Seg(0, 1, "You", "a", Source.Mic, 0),
            Seg(3.0, 4, "You", "b", Source.Mic, 1),
        });
        Assert.Equal(2, b.Count);
    }

    [Fact]
    public void GapExactlyOnePointFiveCoalesces()
    {
        // gap = 2.5 - 1.0 = 1.5, inclusive boundary → coalesce
        var b = Merge.MergeSegments(new[]
        {
            Seg(0, 1, "You", "a", Source.Mic, 0),
            Seg(2.5, 4, "You", "b", Source.Mic, 1),
        });
        Assert.Single(b);
        Assert.Equal("a b", b[0].Text);
    }

    // --- 4. empty dropped + clamp (Selftest case 4) ---
    [Fact]
    public void EmptyDroppedAndClamp()
    {
        var b = Merge.MergeSegments(new[]
        {
            Seg(0, 1, "You", "   ", Source.Mic, 0),
            Seg(1, 0.5, "Them", "x", Source.System, 1),
        });
        Assert.Single(b);
        Assert.Equal("Them", b[0].Label);
        Assert.True(b[0].End >= b[0].Start);
    }

    // --- 5. equal start: mic before system (Selftest case 5) ---
    [Fact]
    public void EqualStartMicBeforeSystem()
    {
        var b = Merge.MergeSegments(new[]
        {
            Seg(1.0, 2.0, "Them", "them", Source.System, 0),
            Seg(1.0, 2.0, "You", "you", Source.Mic, 1),
        });
        Assert.Equal(new[] { "you", "them" }, b.Select(x => x.Text));
    }

    // --- 6. idx tiebreak (unstable sort) (Selftest case 6) ---
    [Fact]
    public void IdxTiebreakWithIdenticalKeys()
    {
        var b = Merge.MergeSegments(new[]
        {
            Seg(0.0, 0.0, "You", "alpha", Source.Mic, 0),
            Seg(0.0, 0.0, "You", "beta", Source.Mic, 1),
            Seg(0.0, 0.0, "You", "gamma", Source.Mic, 2),
        });
        Assert.Single(b);
        Assert.Equal("alpha beta gamma", b[0].Text);
    }

    // --- Extra: idx tiebreak survives a reversed input order ---
    [Fact]
    public void IdxTiebreakIndependentOfInputOrder()
    {
        var b = Merge.MergeSegments(new[]
        {
            Seg(0.0, 0.0, "You", "gamma", Source.Mic, 2),
            Seg(0.0, 0.0, "You", "alpha", Source.Mic, 0),
            Seg(0.0, 0.0, "You", "beta", Source.Mic, 1),
        });
        Assert.Single(b);
        Assert.Equal("alpha beta gamma", b[0].Text);
    }

    // --- Extra: You/Them interleave produces a real back-and-forth, no cross-label coalesce ---
    [Fact]
    public void YouThemInterleaveDoesNotCoalesceAcrossLabels()
    {
        var b = Merge.MergeSegments(new[]
        {
            Seg(0.0, 1.0, "You", "hi", Source.Mic, 0),
            Seg(1.2, 2.0, "Them", "hello", Source.System, 1),
            Seg(2.1, 3.0, "You", "how are you", Source.Mic, 2),
            Seg(3.1, 4.0, "Them", "good", Source.System, 3),
        });
        Assert.Equal(new[] { "You", "Them", "You", "Them" }, b.Select(x => x.Label));
        Assert.Equal(new[] { "hi", "hello", "how are you", "good" }, b.Select(x => x.Text));
    }

    // --- Extra: an interposed other-speaker segment breaks a same-label run ---
    [Fact]
    public void InterposedSpeakerBreaksRun()
    {
        // Two "You" segments within 1.5 s of each other, but "Them" lands between them in time.
        var b = Merge.MergeSegments(new[]
        {
            Seg(0.0, 1.0, "You", "part one", Source.Mic, 0),
            Seg(1.1, 1.4, "Them", "wait", Source.System, 1),
            Seg(1.5, 2.0, "You", "part two", Source.Mic, 2),
        });
        Assert.Equal(3, b.Count);
        Assert.Equal(new[] { "part one", "wait", "part two" }, b.Select(x => x.Text));
    }

    // --- Extra: coalesce takes the max end, not the last end ---
    [Fact]
    public void CoalesceTakesMaxEnd()
    {
        var b = Merge.MergeSegments(new[]
        {
            Seg(0.0, 5.0, "You", "a", Source.Mic, 0),
            Seg(0.1, 2.0, "You", "b", Source.Mic, 1),
        });
        Assert.Single(b);
        Assert.Equal(5.0, b[0].End);
        Assert.Equal("a b", b[0].Text);
    }

    // --- Extra: caller's segments are not mutated ---
    [Fact]
    public void DoesNotMutateInput()
    {
        var input = new[]
        {
            Seg(0.0, 2.0, "You", "hello", Source.Mic, 0),
            Seg(2.1, 3.0, "You", "world", Source.Mic, 1),
        };
        _ = Merge.MergeSegments(input);
        Assert.Equal("hello", input[0].Text);
        Assert.Equal(2.0, input[0].End);
    }
}
