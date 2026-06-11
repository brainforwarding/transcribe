using NAudio.CoreAudioApi;

namespace Transcribe.App;

/// <summary>A selectable microphone (capture endpoint). Mirrors the macOS MicDevice.</summary>
public sealed record MicDeviceInfo(string Id, string Name);

/// <summary>Enumerates active capture (recording) endpoints for the mic picker.</summary>
public static class MicEnumerator
{
    public static List<MicDeviceInfo> Available()
    {
        var list = new List<MicDeviceInfo>();
        try
        {
            using var en = new MMDeviceEnumerator();
            foreach (var d in en.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active))
            {
                list.Add(new MicDeviceInfo(d.ID, d.FriendlyName));
                d.Dispose();
            }
        }
        catch
        {
            // No devices / COM failure → empty list; the app falls back to the system default.
        }
        return list;
    }
}
