using System.Globalization;

namespace Transcribe.Core;

public static class Render
{
    /// <summary>
    /// <c>[mm:ss]</c> with round-half-to-even (banker's rounding), matching Python's
    /// <c>round()</c> in meetrec.py <c>_mmss</c> and Swift's <c>.toNearestOrEven</c>.
    ///
    /// C#'s Math.Round defaults to MidpointRounding.ToEven, so round(30.5)=30 and
    /// round(31.5)=32 — identical to the macOS app. Clamp to ≥ 0 first.
    /// </summary>
    public static string Mmss(double t)
    {
        var s = (int)Math.Round(Math.Max(0.0, t), MidpointRounding.ToEven);
        return string.Format(CultureInfo.InvariantCulture, "{0:00}:{1:00}", s / 60, s % 60);
    }

    /// <summary>
    /// Port of meetrec.py <c>render_conversation</c> / Swift <c>renderConversation</c>.
    /// Meeting mode: <c>[mm:ss] **Label:** text</c>, blocks separated by a blank line.
    /// </summary>
    public static string RenderConversation(IEnumerable<Segment> blocks, bool timestamps = true)
    {
        return string.Join("\n\n", blocks.Select(b =>
        {
            var prefix = timestamps ? $"[{Mmss(b.Start)}] " : "";
            return $"{prefix}**{b.Label}:** {b.Text}";
        }));
    }

    /// <summary>
    /// Single-track (mic-only / "Just me") render: no speaker labels, no timestamps —
    /// plain flowing paragraphs, one per merged block (MergeSegments splits blocks on
    /// &gt;1.5 s pauses). Port of Swift <c>renderPlain</c>.
    /// </summary>
    public static string RenderPlain(IEnumerable<Segment> blocks)
    {
        return string.Join("\n\n", blocks.Select(b => b.Text));
    }

    /// <summary>
    /// Port of meetrec.py <c>render_appendix</c> / Swift <c>renderAppendix</c>: verbatim
    /// per-track text (ground truth, independent of the merge).
    /// </summary>
    public static string RenderAppendix(IEnumerable<(string Heading, IReadOnlyList<Segment> Segments)> tracks)
    {
        return string.Join("\n\n", tracks.Select(t =>
        {
            var body = string.Join(" ", t.Segments.Select(s => s.Text)).Trim();
            return $"### {t.Heading}\n\n{(body.Length == 0 ? "_(no speech detected)_" : body)}";
        }));
    }
}
