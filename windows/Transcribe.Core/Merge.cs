namespace Transcribe.Core;

public static class Merge
{
    /// <summary>
    /// Same-speaker segments closer than this (seconds) are coalesced. Mirrors
    /// meetrec.py COALESCE_GAP and Swift coalesceGap. Constant, not a setting.
    /// </summary>
    public const double CoalesceGap = 1.5;

    /// <summary>
    /// Pure port of meetrec.py <c>merge_segments</c> / Swift <c>mergeSegments</c>:
    /// drop empties, clamp non-monotonic ends, sort on the global clock by
    /// (start, source, end, idx), then coalesce SORTED-ADJACENT same-label segments
    /// whose gap ≤ <paramref name="gap"/> (an interposed other-speaker segment breaks
    /// the run, so chronology is preserved). Returns ordered blocks.
    ///
    /// The (source, idx) tiebreak makes the ordering total and deterministic despite
    /// List.Sort being an unstable introsort — this is what pins the output
    /// byte-identical to the macOS app.
    /// </summary>
    public static List<Segment> MergeSegments(IEnumerable<Segment> input, double gap = CoalesceGap)
    {
        // Drop empty (whitespace-only) text; work on copies so we never mutate the caller's data.
        var segs = input
            .Where(s => !string.IsNullOrEmpty(s.Text.Trim()))
            .Select(s => s.Clone())
            .ToList();

        // Clamp non-monotonic spans (end < start → end = start).
        foreach (var s in segs)
        {
            if (s.End < s.Start) s.End = s.Start;
        }

        // Total ordering: (start, source, end, idx).
        segs.Sort((a, b) =>
        {
            if (a.Start != b.Start) return a.Start < b.Start ? -1 : 1;
            if (a.Source != b.Source) return (int)a.Source < (int)b.Source ? -1 : 1;
            if (a.End != b.End) return a.End < b.End ? -1 : 1;
            return a.Idx.CompareTo(b.Idx);
        });

        var blocks = new List<Segment>();
        foreach (var s in segs)
        {
            var last = blocks.Count > 0 ? blocks[^1] : null;
            if (last != null && last.Label == s.Label && (s.Start - last.End) <= gap)
            {
                last.End = Math.Max(last.End, s.End);
                last.Text = (last.Text + " " + s.Text).Trim();
            }
            else
            {
                blocks.Add(s.Clone());
            }
        }
        return blocks;
    }
}
