using System.Windows.Forms;

namespace Transcribe.App;

internal static class Program
{
    /// <summary>
    /// Entry point. Single-instance tray app: if another copy is already running, surface it and
    /// exit. No main window — everything lives behind the NotifyIcon (see <see cref="TrayApp"/>).
    /// </summary>
    [STAThread]
    private static void Main()
    {
        using var single = new Mutex(initiallyOwned: true, "Transcribe.App.SingleInstance", out var isNew);
        if (!isNew)
        {
            // Already running — nothing to do; the existing instance owns the tray icon.
            return;
        }

        ApplicationConfiguration.Initialize();
        Application.Run(new TrayApp());
    }
}
