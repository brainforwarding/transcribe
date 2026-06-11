using System.Drawing;
using System.Windows.Forms;
using Transcribe.Core;

namespace Transcribe.App;

/// <summary>
/// Settings flyout (port of SettingsView): save folder, Keep audio, Add summary, Replace token
/// (same verify-on-save UX + last-4 fingerprint), and the subtle "Transcribe vX.Y.Z" version.
/// </summary>
public sealed class SettingsForm : Form
{
    private readonly AppSettings _settings;
    private readonly Summarizer _summarizer;

    private Label _folderLabel = null!;
    private Label _tokenStatus = null!;
    private TextBox? _replaceField;
    private Button _replaceBtn = null!;
    private Panel _replacePanel = null!;

    public SettingsForm(AppSettings settings, Summarizer summarizer)
    {
        _settings = settings;
        _summarizer = summarizer;

        Text = "Settings";
        FormBorderStyle = FormBorderStyle.FixedDialog;
        StartPosition = FormStartPosition.CenterParent;
        MinimizeBox = false;
        MaximizeBox = false;
        ShowInTaskbar = false;
        ClientSize = new Size(420, 360);
        Font = new Font("Segoe UI", 9F);

        BuildUi();
    }

    private void BuildUi()
    {
        var usesProxy = AppConfig.ProxyBaseUrl != null;
        var title = new Label
        {
            Text = "Settings", AutoSize = true, Location = new Point(18, 16),
            Font = new Font("Segoe UI", 13F, FontStyle.Bold),
        };

        // Save folder
        var saveTo = new Label { Text = "Save to", AutoSize = true, Location = new Point(18, 56) };
        _folderLabel = new Label
        {
            Text = TruncatePath(_settings.SaveFolder), AutoSize = false,
            Location = new Point(90, 54), Size = new Size(230, 20), ForeColor = Color.DimGray,
            AutoEllipsis = true,
        };
        var change = new Button { Text = "Change…", Location = new Point(326, 50), Width = 76 };
        change.Click += (_, _) => ChooseFolder();

        // Toggles
        var keep = new CheckBox
        {
            Text = "Keep audio files", Checked = _settings.KeepAudio,
            Location = new Point(18, 86), AutoSize = true,
        };
        keep.CheckedChanged += (_, _) => { _settings.KeepAudio = keep.Checked; _settings.Save(); };

        var summary = new CheckBox
        {
            Text = "Add a summary to each transcript (extra OpenAI cost)", Checked = _settings.IncludeSummary,
            Location = new Point(18, 112), AutoSize = true,
        };
        summary.CheckedChanged += (_, _) => { _settings.IncludeSummary = summary.Checked; _settings.Save(); };

        // Token row
        var tokenLabel = new Label
        {
            Text = usesProxy ? "Team token" : "OpenAI key", AutoSize = true, Location = new Point(18, 152),
        };
        _tokenStatus = new Label
        {
            Text = FingerprintText(), AutoSize = false, Location = new Point(110, 152),
            Size = new Size(210, 20), ForeColor = Color.DimGray,
        };
        _replaceBtn = new Button { Text = "Replace…", Location = new Point(326, 148), Width = 76 };
        _replaceBtn.Click += (_, _) => ToggleReplace();

        _replacePanel = new Panel
        {
            Location = new Point(18, 178), Size = new Size(384, 36), Visible = false,
        };

        // Consent reminder (meeting mode only)
        var consent = new Label
        {
            Text = "⚠ Recording captures everyone in the call. Inform participants and get their " +
                   "consent — it's legally required in some places.",
            AutoSize = false, Location = new Point(18, 224), Size = new Size(384, 50),
            ForeColor = Color.DimGray, Visible = !_settings.MicOnly,
        };

        // Version + quit
        var version = new Label
        {
            Text = $"Transcribe {AppVersion.Display}", AutoSize = true,
            Location = new Point(18, 326), ForeColor = Color.Silver, Font = new Font("Segoe UI", 8F),
        };
        var quit = new Button { Text = "Quit Transcribe", Location = new Point(294, 320), Width = 108 };
        quit.Click += (_, _) => Application.Exit();

        Controls.AddRange(new Control[]
        {
            title, saveTo, _folderLabel, change, keep, summary,
            tokenLabel, _tokenStatus, _replaceBtn, _replacePanel, consent, version, quit,
        });
    }

    private void ToggleReplace()
    {
        if (_replacePanel.Visible)
        {
            _replacePanel.Visible = false;
            _replacePanel.Controls.Clear();
            _replaceBtn.Text = "Replace…";
            _tokenStatus.ForeColor = Color.DimGray;
            _tokenStatus.Text = FingerprintText();
            return;
        }

        _replaceBtn.Text = "Cancel";
        _replacePanel.Controls.Clear();
        _replaceField = new TextBox
        {
            Location = new Point(0, 4), Width = 290, UseSystemPasswordChar = true,
            PlaceholderText = AppConfig.ProxyBaseUrl != null ? "team token" : "sk-…",
        };
        var save = new Button { Text = "Save", Location = new Point(300, 2), Width = 80 };

        async void DoSave() => await SaveReplacementAsync(_replaceField.Text);
        save.Click += (_, _) => DoSave();
        _replaceField.KeyDown += (_, e) =>
        {
            if (e.KeyCode == Keys.Enter) { e.SuppressKeyPress = true; DoSave(); }
        };

        _replacePanel.Controls.Add(_replaceField);
        _replacePanel.Controls.Add(save);
        _replacePanel.Visible = true;
        _replaceField.Focus();
    }

    private async Task SaveReplacementAsync(string raw)
    {
        var token = raw.Trim();
        if (token.Length == 0) return;
        CredentialStore.Set(token);

        if (AppConfig.ProxyBaseUrl == null)
        {
            _tokenStatus.ForeColor = Color.Green;
            _tokenStatus.Text = "✓ saved";
            CollapseReplaceAfterDelay();
            return;
        }

        _tokenStatus.ForeColor = Color.DimGray;
        _tokenStatus.Text = "verifying…";
        var result = await _summarizer.VerifyTokenAsync(AppConfig.ProxyBaseUrl, token);
        switch (result)
        {
            case Summarizer.VerifyResult.Accepted:
                _tokenStatus.ForeColor = Color.Green;
                _tokenStatus.Text = "✓ verified";
                CollapseReplaceAfterDelay();
                break;
            case Summarizer.VerifyResult.Rejected:
                _tokenStatus.ForeColor = Color.Firebrick;
                _tokenStatus.Text = "✗ token not recognized";
                break;
            case Summarizer.VerifyResult.Unreachable:
                _tokenStatus.ForeColor = Color.DimGray;
                _tokenStatus.Text = "saved — couldn't verify (offline?)";
                CollapseReplaceAfterDelay();
                break;
        }
    }

    private void CollapseReplaceAfterDelay()
    {
        var t = new System.Windows.Forms.Timer { Interval = 2500 };
        t.Tick += (_, _) =>
        {
            t.Stop(); t.Dispose();
            if (!IsDisposed)
            {
                _replacePanel.Visible = false;
                _replacePanel.Controls.Clear();
                _replaceBtn.Text = "Replace…";
                _tokenStatus.ForeColor = Color.DimGray;
                _tokenStatus.Text = FingerprintText();
            }
        };
        t.Start();
    }

    private static string FingerprintText()
    {
        var fp = CredentialStore.Fingerprint();
        return fp == null ? "not set" : $"•••• {fp} stored";
    }

    private void ChooseFolder()
    {
        using var dlg = new FolderBrowserDialog
        {
            SelectedPath = Directory.Exists(_settings.SaveFolder)
                ? _settings.SaveFolder
                : AppSettings.DefaultSaveFolder(),
        };
        if (dlg.ShowDialog(this) == DialogResult.OK)
        {
            _settings.SaveFolder = dlg.SelectedPath;
            _settings.Save();
            _folderLabel.Text = TruncatePath(_settings.SaveFolder);
        }
    }

    private static string TruncatePath(string path) =>
        path.Length <= 40 ? path : "…" + path[^39..];
}
