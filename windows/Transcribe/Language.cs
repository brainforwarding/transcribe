namespace Transcribe.App;

/// <summary>Language option for the picker. Mirrors the macOS LanguageOption: Auto, English,
/// Spanish (default), Portuguese. Code is null for "auto" (no language field sent to whisper).</summary>
public sealed record LanguageOption(string Id, string Name)
{
    public string? Code => Id == "auto" ? null : Id;

    public static readonly IReadOnlyList<LanguageOption> All = new[]
    {
        new LanguageOption("auto", "Auto"),
        new LanguageOption("en", "English"),
        new LanguageOption("es", "Spanish"),
        new LanguageOption("pt", "Portuguese"),
    };

    public static LanguageOption ForId(string id) =>
        All.FirstOrDefault(l => l.Id == id) ?? All[2]; // default Spanish
}
