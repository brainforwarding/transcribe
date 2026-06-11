namespace Transcribe.Core;

/// <summary>
/// Which physical track a segment came from. The integer value is the merge tiebreak
/// rank — Mic (0) sorts before System (1) at equal start times, matching the Python
/// merge_segments which sorts the ASCII strings "mic" &lt; "system", and the Swift
/// Source enum (mic=0, system=1).
/// </summary>
public enum Source
{
    Mic = 0,
    System = 1,
}

/// <summary>
/// One transcribed span on the global (shared) timeline. <c>Idx</c> is an input-order
/// tiebreak: List.Sort is NOT a stable sort, so we carry the original concatenation order
/// (mic segments first, then system) to reproduce the tested macOS/Python output exactly.
/// Mirrors the Swift <c>Segment</c> struct.
/// </summary>
public sealed class Segment : IEquatable<Segment>
{
    public double Start { get; set; }
    public double End { get; set; }
    public string Label { get; set; }
    public string Text { get; set; }
    public Source Source { get; set; }
    public int Idx { get; set; }

    public Segment(double start, double end, string label, string text, Source source, int idx = 0)
    {
        Start = start;
        End = end;
        Label = label;
        Text = text;
        Source = source;
        Idx = idx;
    }

    /// <summary>Shallow copy — mirrors Swift's value-type copy in mergeSegments.</summary>
    public Segment Clone() => new(Start, End, Label, Text, Source, Idx);

    public bool Equals(Segment? other)
    {
        if (other is null) return false;
        return Start.Equals(other.Start)
            && End.Equals(other.End)
            && Label == other.Label
            && Text == other.Text
            && Source == other.Source
            && Idx == other.Idx;
    }

    public override bool Equals(object? obj) => Equals(obj as Segment);

    public override int GetHashCode() => HashCode.Combine(Start, End, Label, Text, Source, Idx);
}
