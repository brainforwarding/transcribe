using System.Text.Json;
using System.Text.Json.Serialization;

namespace Transcribe.App;

/// <summary>
/// Persisted user settings — the WinForms analog of the macOS app's UserDefaults-backed
/// AppModel properties. Stored as JSON under %APPDATA%\Transcribe\settings.json.
///
/// Defaults match the macOS app exactly: language "es" (Spanish), Meeting mode (MicOnly=false),
/// KeepAudio/IncludeSummary off, save folder %USERPROFILE%\Documents\Transcribe.
/// </summary>
public sealed class AppSettings
{
    [JsonPropertyName("saveFolder")]
    public string SaveFolder { get; set; } = DefaultSaveFolder();

    [JsonPropertyName("keepAudio")]
    public bool KeepAudio { get; set; }

    [JsonPropertyName("includeSummary")]
    public bool IncludeSummary { get; set; }

    /// <summary>"Just me" mode — mic only, no loopback, no You/Them labels. Default false (Meeting).</summary>
    [JsonPropertyName("micOnly")]
    public bool MicOnly { get; set; }

    /// <summary>"auto" | "en" | "es" | "pt". Default "es" (Spanish), persisted — matches macOS.</summary>
    [JsonPropertyName("languageId")]
    public string LanguageId { get; set; } = "es";

    /// <summary>Selected mic device id; null = system default input.</summary>
    [JsonPropertyName("selectedMicId")]
    public string? SelectedMicId { get; set; }

    [JsonPropertyName("consentAccepted")]
    public bool ConsentAccepted { get; set; }

    // ---- persistence ----

    private static readonly JsonSerializerOptions JsonOpts = new() { WriteIndented = true };

    [JsonIgnore]
    public static string ConfigDir =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Transcribe");

    [JsonIgnore]
    public static string ConfigPath => Path.Combine(ConfigDir, "settings.json");

    public static string DefaultSaveFolder() =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "Transcribe");

    public static AppSettings Load()
    {
        try
        {
            if (File.Exists(ConfigPath))
            {
                var json = File.ReadAllText(ConfigPath);
                var loaded = JsonSerializer.Deserialize<AppSettings>(json);
                if (loaded != null)
                {
                    if (string.IsNullOrWhiteSpace(loaded.SaveFolder)) loaded.SaveFolder = DefaultSaveFolder();
                    if (string.IsNullOrWhiteSpace(loaded.LanguageId)) loaded.LanguageId = "es";
                    return loaded;
                }
            }
        }
        catch
        {
            // Corrupt settings → fall back to defaults rather than crash on launch.
        }
        return new AppSettings();
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(ConfigDir);
            File.WriteAllText(ConfigPath, JsonSerializer.Serialize(this, JsonOpts));
        }
        catch
        {
            // Non-fatal; settings just won't persist this session.
        }
    }
}
