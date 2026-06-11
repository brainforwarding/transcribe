using System.Globalization;
using System.Text;

namespace Transcribe.Core;

public static class Naming
{
    /// <summary>
    /// Filename slug for a user-entered recording title: diacritics folded ("café" → "cafe"),
    /// lowercased, every run of non-alphanumerics collapsed to a single hyphen, trimmed, and
    /// hard-capped at <paramref name="maxLength"/> (trailing hyphen dropped). Returns "" if
    /// nothing survives.
    ///
    /// Port of Swift <c>slugify</c>. Diacritic folding is done by Unicode NFD decomposition
    /// then dropping non-spacing combining marks (so "é" → "e"), matching
    /// <c>folding(options: .diacriticInsensitive)</c>. Only ASCII a–z / 0–9 survive; anything
    /// else becomes a single hyphen, exactly like the macOS app's unicodeScalars loop.
    /// </summary>
    public static string Slugify(string title, int maxLength = 60)
    {
        var folded = FoldDiacritics(title).ToLowerInvariant();

        var slug = new StringBuilder();
        foreach (var ch in folded)
        {
            if ((ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9'))
            {
                slug.Append(ch);
            }
            else
            {
                // collapse runs of non-alphanumerics to a single hyphen, no leading hyphen
                if (slug.Length > 0 && slug[^1] != '-') slug.Append('-');
            }
        }

        TrimTrailingHyphens(slug);

        if (slug.Length > maxLength)
        {
            slug.Length = maxLength;
            TrimTrailingHyphens(slug);
        }

        return slug.ToString();
    }

    /// <summary>
    /// Filename stem (no extension) for a recording: <c>YYYY-MM-DD-&lt;slug&gt;</c> when the
    /// title slugs to something usable, else the full timestamp stamp. <paramref name="stamp"/>
    /// is the <c>yyyy-MM-dd_HH-mm-ss</c> recording stamp. Port of Swift <c>transcriptStem</c>.
    /// </summary>
    public static string TranscriptStem(string stamp, string? title)
    {
        var slug = Slugify(title ?? "");
        if (slug.Length == 0) return stamp;
        // stamp.prefix(10) == "yyyy-MM-dd"
        var datePart = stamp.Length >= 10 ? stamp.Substring(0, 10) : stamp;
        return $"{datePart}-{slug}";
    }

    /// <summary>
    /// First non-colliding <c>&lt;stem&gt;.md</c> name: <c>stem.md</c>, then <c>stem-2.md</c>,
    /// <c>stem-3.md</c>, … <paramref name="exists"/> is injectable for tests (it receives the
    /// candidate file name, e.g. "a-2.md"). Port of Swift <c>availableTranscriptURL</c>.
    /// </summary>
    public static string AvailableTranscriptName(string stem, Func<string, bool> exists)
    {
        var name = $"{stem}.md";
        var n = 2;
        while (exists(name))
        {
            name = $"{stem}-{n}.md";
            n++;
        }
        return name;
    }

    /// <summary>
    /// Filesystem-backed overload: returns the absolute path of the first free
    /// <c>&lt;stem&gt;.md</c> inside <paramref name="dir"/>.
    /// </summary>
    public static string AvailableTranscriptPath(string dir, string stem)
    {
        var name = AvailableTranscriptName(stem, n => File.Exists(Path.Combine(dir, n)));
        return Path.Combine(dir, name);
    }

    private static void TrimTrailingHyphens(StringBuilder sb)
    {
        while (sb.Length > 0 && sb[^1] == '-') sb.Length--;
    }

    private static string FoldDiacritics(string input)
    {
        var decomposed = input.Normalize(NormalizationForm.FormD);
        var sb = new StringBuilder(decomposed.Length);
        foreach (var ch in decomposed)
        {
            // Drop non-spacing combining marks (the accents detached by NFD).
            if (CharUnicodeInfo.GetUnicodeCategory(ch) != UnicodeCategory.NonSpacingMark)
            {
                sb.Append(ch);
            }
        }
        return sb.ToString().Normalize(NormalizationForm.FormC);
    }
}
