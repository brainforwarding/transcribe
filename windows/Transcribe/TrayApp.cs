using System.Drawing;
using System.Windows.Forms;
using Transcribe.Core;

namespace Transcribe.App;

/// <summary>
/// Tray application context: a NotifyIcon with no taskbar window. Left-click toggles the flyout
/// popup near the cursor; right-click opens a small context menu (Open / Settings / Quit). This
/// is the Windows analog of the macOS NSStatusItem + popover.
/// </summary>
public sealed class TrayApp : ApplicationContext
{
    private readonly NotifyIcon _icon;
    private readonly PopupForm _popup;

    public TrayApp()
    {
        var settings = AppSettings.Load();

        var http = new HttpClient { Timeout = TimeSpan.FromMinutes(10) };
        var transcriber = new Transcriber(http);
        var summarizer = new Summarizer(http);
        var segmenter = new NAudioSegmenter();
        var pipeline = new Pipeline(segmenter, transcriber, summarizer);
        var controller = new RecordingController(settings, pipeline);

        _popup = new PopupForm(settings, controller, summarizer);

        var menu = new ContextMenuStrip();
        menu.Items.Add("Open", null, (_, _) => ShowPopup());
        menu.Items.Add("Settings…", null, (_, _) =>
        {
            using var f = new SettingsForm(settings, summarizer);
            f.ShowDialog();
        });
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add($"Transcribe {AppVersion.Display}", null, null).Enabled = false;
        menu.Items.Add("Quit", null, (_, _) => ExitThread());

        _icon = new NotifyIcon
        {
            Icon = LoadIcon(),
            Visible = true,
            Text = "Transcribe",
            ContextMenuStrip = menu,
        };
        _icon.MouseClick += (_, e) =>
        {
            if (e.Button == MouseButtons.Left) ShowPopup();
        };
    }

    private void ShowPopup()
    {
        if (_popup.Visible) { _popup.Hide(); return; }
        _popup.ShowNear(Cursor.Position);
    }

    private static Icon LoadIcon()
    {
        // Prefer a bundled app.ico if present; otherwise fall back to a system icon so the tray
        // is never blank. (Add windows/Transcribe/app.ico and wire <ApplicationIcon> to brand it.)
        try
        {
            var path = Path.Combine(AppContext.BaseDirectory, "app.ico");
            if (File.Exists(path)) return new Icon(path);
        }
        catch { /* fall through */ }
        return SystemIcons.Application;
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _icon.Visible = false;
            _icon.Dispose();
            _popup.Dispose();
        }
        base.Dispose(disposing);
    }
}
