using System.Reflection;

namespace Transcribe.App;

/// <summary>App version for the subtle "Transcribe vX.Y.Z" display, read from the assembly's
/// InformationalVersion (set in the .csproj). Mirrors the macOS CFBundleShortVersionString read.</summary>
public static class AppVersion
{
    public static string Short
    {
        get
        {
            var info = Assembly.GetExecutingAssembly()
                .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion;
            if (!string.IsNullOrEmpty(info))
            {
                // Strip any "+<commit>" build metadata SourceLink may append.
                var plus = info.IndexOf('+');
                return plus >= 0 ? info[..plus] : info;
            }
            var v = Assembly.GetExecutingAssembly().GetName().Version;
            return v == null ? "?" : $"{v.Major}.{v.Minor}.{v.Build}";
        }
    }

    public static string Display => $"v{Short}";
}
