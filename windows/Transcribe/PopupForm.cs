using System.Drawing;
using System.Windows.Forms;
using Transcribe.Core;

namespace Transcribe.App;

/// <summary>
/// The tray flyout — the Windows analog of the macOS popover (ContentView). It swaps between
/// consent, token entry, and the main record panel, and hosts the inline Settings panel. No
/// taskbar window; it's shown anchored near the tray icon and hides on deactivate.
/// </summary>
public sealed class PopupForm : Form
{
    private readonly AppSettings _settings;
    private readonly RecordingController _controller;
    private readonly Summarizer _summarizer;

    private readonly Panel _body;
    private System.Windows.Forms.Timer? _elapsedTimer;
    private int _elapsed;

    private enum Phase { Idle, Recording, Transcribing, Done, Error }
    private Phase _phase = Phase.Idle;
    private string _status = "";
    private string? _lastTranscript;

    public PopupForm(AppSettings settings, RecordingController controller, Summarizer summarizer)
    {
        _settings = settings;
        _controller = controller;
        _summarizer = summarizer;

        FormBorderStyle = FormBorderStyle.FixedToolWindow;
        StartPosition = FormStartPosition.Manual;
        ShowInTaskbar = false;
        Text = "Transcribe";
        ClientSize = new Size(320, 280);
        BackColor = Color.FromArgb(245, 245, 247);
        Font = new Font("Segoe UI", 9F);

        _body = new Panel { Dock = DockStyle.Fill, Padding = new Padding(14) };
        Controls.Add(_body);

        Deactivate += (_, _) => Hide();
        Render();
    }

    // Hide instead of close when the user clicks the X or it loses focus.
    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (e.CloseReason == CloseReason.UserClosing)
        {
            e.Cancel = true;
            Hide();
        }
        else
        {
            base.OnFormClosing(e);
        }
    }

    public void ShowNear(Point anchor)
    {
        var screen = Screen.FromPoint(anchor).WorkingArea;
        var x = Math.Min(anchor.X, screen.Right - Width - 8);
        var y = Math.Min(anchor.Y - Height, screen.Bottom - Height - 8);
        Location = new Point(Math.Max(screen.Left + 8, x), Math.Max(screen.Top + 8, y));
        Render();
        Show();
        Activate();
    }

    private bool HasKey => CredentialStore.Get() != null;
    private bool Ready => _settings.ConsentAccepted && HasKey;

    private void Render()
    {
        _body.Controls.Clear();
        if (!_settings.ConsentAccepted) RenderConsent();
        else if (!HasKey) RenderKeyEntry();
        else RenderMain();
    }

    // ---- onboarding: consent ----

    private void RenderConsent()
    {
        ClientSize = new Size(320, 230);
        var title = MakeHeader("Before you record");
        var note = new Label
        {
            Text = "This captures your mic and everyone else's audio and uploads it to OpenAI " +
                   "to transcribe. Tell participants and get their consent. Transcripts are " +
                   "saved on your PC.",
            AutoSize = false,
            Location = new Point(14, 44),
            Size = new Size(292, 110),
            ForeColor = Color.DimGray,
        };
        var btn = new Button
        {
            Text = "I understand — continue",
            Location = new Point(14, 164),
            Size = new Size(292, 36),
        };
        btn.Click += (_, _) =>
        {
            _settings.ConsentAccepted = true;
            _settings.Save();
            Render();
        };
        _body.Controls.Add(title);
        _body.Controls.Add(note);
        _body.Controls.Add(btn);
    }

    // ---- onboarding: token entry ----

    private TextBox? _keyField;
    private Label? _keyStatusLabel;

    private void RenderKeyEntry()
    {
        ClientSize = new Size(320, 210);
        var usesProxy = AppConfig.ProxyBaseUrl != null;
        var title = MakeHeader(usesProxy ? "Add your team token" : "Add your OpenAI key");
        var note = new Label
        {
            Text = usesProxy
                ? "Stored securely in Windows Credential Manager. Ask your team admin for your token."
                : "Stored securely in Windows Credential Manager.",
            AutoSize = false,
            Location = new Point(14, 44),
            Size = new Size(292, 40),
            ForeColor = Color.DimGray,
        };

        _keyField = new TextBox
        {
            Location = new Point(14, 92),
            Width = 210,
            UseSystemPasswordChar = true,
            PlaceholderText = usesProxy ? "team token" : "sk-…",
        };
        var save = new Button { Text = "Save", Location = new Point(231, 90), Width = 75 };
        _keyStatusLabel = new Label
        {
            Location = new Point(14, 126),
            Size = new Size(292, 40),
            ForeColor = Color.DimGray,
        };

        async void DoSave()
        {
            await SaveAndVerifyKeyAsync(_keyField.Text, _keyStatusLabel, onAccepted: () =>
            {
                _keyField.Clear();
                Render();
            });
        }

        save.Click += (_, _) => DoSave();
        _keyField.KeyDown += (_, e) =>
        {
            if (e.KeyCode == Keys.Enter) { e.SuppressKeyPress = true; DoSave(); }
        };

        _body.Controls.Add(title);
        _body.Controls.Add(note);
        _body.Controls.Add(_keyField);
        _body.Controls.Add(save);
        _body.Controls.Add(_keyStatusLabel);
    }

    /// <summary>
    /// Token verify-on-save UX (port of saveAndVerifyKey): store → "verifying…" → "✓ verified"
    /// / "✗ not recognized" / "saved — couldn't verify (offline?)". 401 = rejected (keep the
    /// field open); anything else = accepted; network error = saved-unverified.
    /// </summary>
    private async Task SaveAndVerifyKeyAsync(string raw, Label status, Action onAccepted)
    {
        var token = raw.Trim();
        if (token.Length == 0) return;

        CredentialStore.Set(token);

        if (AppConfig.ProxyBaseUrl == null)
        {
            status.ForeColor = Color.Green;
            status.Text = "✓ saved";
            onAccepted();
            return;
        }

        status.ForeColor = Color.DimGray;
        status.Text = "verifying…";
        var result = await _summarizer.VerifyTokenAsync(AppConfig.ProxyBaseUrl, token);
        switch (result)
        {
            case Summarizer.VerifyResult.Accepted:
                status.ForeColor = Color.Green;
                status.Text = "✓ verified";
                onAccepted();
                break;
            case Summarizer.VerifyResult.Rejected:
                status.ForeColor = Color.Firebrick;
                status.Text = "✗ token not recognized — check it and try again";
                break;
            case Summarizer.VerifyResult.Unreachable:
                status.ForeColor = Color.DimGray;
                status.Text = "saved — couldn't verify (offline?)";
                onAccepted();
                break;
        }
    }

    // ---- main ----

    private ComboBox? _micCombo;
    private ComboBox? _langCombo;

    private void RenderMain()
    {
        switch (_phase)
        {
            case Phase.Recording: RenderRecording(); return;
            case Phase.Transcribing: RenderTranscribing(); return;
            default: RenderIdle(); return;
        }
    }

    private void RenderIdle()
    {
        ClientSize = new Size(320, 300);
        var y = 8;

        // Mic picker
        _body.Controls.Add(MakeRowLabel("Mic", y + 4));
        _micCombo = new ComboBox
        {
            DropDownStyle = ComboBoxStyle.DropDownList,
            Location = new Point(78, y),
            Width = 228,
        };
        _micCombo.Items.Add(new ComboItem(null, "System default"));
        foreach (var d in MicEnumerator.Available()) _micCombo.Items.Add(new ComboItem(d.Id, d.Name));
        SelectComboById(_micCombo, _settings.SelectedMicId);
        _micCombo.SelectedIndexChanged += (_, _) =>
        {
            _settings.SelectedMicId = (_micCombo.SelectedItem as ComboItem)?.Id;
            _settings.Save();
        };
        _body.Controls.Add(_micCombo);
        y += 34;

        // Language picker
        _body.Controls.Add(MakeRowLabel("Language", y + 4));
        _langCombo = new ComboBox
        {
            DropDownStyle = ComboBoxStyle.DropDownList,
            Location = new Point(78, y),
            Width = 228,
        };
        foreach (var l in LanguageOption.All) _langCombo.Items.Add(new ComboItem(l.Id, l.Name));
        SelectComboById(_langCombo, _settings.LanguageId);
        _langCombo.SelectedIndexChanged += (_, _) =>
        {
            _settings.LanguageId = (_langCombo.SelectedItem as ComboItem)?.Id ?? "es";
            _settings.Save();
        };
        _body.Controls.Add(_langCombo);
        y += 38;

        // Mode segmented (Meeting | Just me)
        _body.Controls.Add(MakeRowLabel("Mode", y + 4));
        var meeting = new RadioButton
        {
            Text = "Meeting", Appearance = Appearance.Button, AutoSize = false,
            Size = new Size(112, 26), Location = new Point(78, y), TextAlign = ContentAlignment.MiddleCenter,
            Checked = !_settings.MicOnly,
        };
        var justMe = new RadioButton
        {
            Text = "Just me", Appearance = Appearance.Button, AutoSize = false,
            Size = new Size(112, 26), Location = new Point(194, y), TextAlign = ContentAlignment.MiddleCenter,
            Checked = _settings.MicOnly,
        };
        meeting.CheckedChanged += (_, _) => { if (meeting.Checked) { _settings.MicOnly = false; _settings.Save(); } };
        justMe.CheckedChanged += (_, _) => { if (justMe.Checked) { _settings.MicOnly = true; _settings.Save(); } };
        var toolTip = new ToolTip();
        toolTip.SetToolTip(meeting, "Meeting: you + everyone on the call (You/Them transcript), records system audio via loopback.");
        toolTip.SetToolTip(justMe, "Just me: your voice only — notes, self-interviews. No system audio.");
        _body.Controls.Add(meeting);
        _body.Controls.Add(justMe);
        y += 40;

        var record = new Button
        {
            Text = "● Record",
            Location = new Point(14, y),
            Size = new Size(292, 38),
            BackColor = Color.FromArgb(0, 120, 215),
            ForeColor = Color.White,
            FlatStyle = FlatStyle.Flat,
        };
        record.Click += async (_, _) => await StartAsync();
        _body.Controls.Add(record);
        y += 46;

        if (_status.Length > 0)
        {
            _body.Controls.Add(new Label
            {
                Text = _status, AutoSize = false, Location = new Point(14, y),
                Size = new Size(292, 32), ForeColor = Color.DimGray,
            });
            y += 34;
        }

        AddFooter(y);
    }

    private void RenderRecording()
    {
        ClientSize = new Size(320, 180);
        var label = new Label
        {
            Text = "00:00",
            Font = new Font("Consolas", 30F, FontStyle.Regular),
            AutoSize = false,
            TextAlign = ContentAlignment.MiddleCenter,
            Size = new Size(292, 60),
            Location = new Point(14, 18),
        };
        var dot = new Label
        {
            Text = "●", ForeColor = Color.Red, Font = new Font("Segoe UI", 14F),
            AutoSize = true, Location = new Point(120, 30),
        };
        if (_settings.MicOnly)
        {
            _body.Controls.Add(new Label
            {
                Text = "Just me", AutoSize = false, TextAlign = ContentAlignment.MiddleCenter,
                Size = new Size(292, 18), Location = new Point(14, 82), ForeColor = Color.DimGray,
            });
        }
        var stop = new Button
        {
            Text = "■ Stop", Location = new Point(14, 110), Size = new Size(292, 38),
            BackColor = Color.Firebrick, ForeColor = Color.White, FlatStyle = FlatStyle.Flat,
        };
        stop.Click += async (_, _) => await StopAsync();

        _body.Controls.Add(label);
        _body.Controls.Add(dot);
        _body.Controls.Add(stop);

        _elapsed = 0;
        label.Text = "00:00";
        _elapsedTimer?.Dispose();
        _elapsedTimer = new System.Windows.Forms.Timer { Interval = 1000 };
        _elapsedTimer.Tick += (_, _) =>
        {
            _elapsed++;
            label.Text = $"{_elapsed / 60:00}:{_elapsed % 60:00}";
        };
        _elapsedTimer.Start();
    }

    private void RenderTranscribing()
    {
        ClientSize = new Size(320, 140);
        _body.Controls.Add(new Label
        {
            Text = "Transcribing…", AutoSize = false, TextAlign = ContentAlignment.MiddleCenter,
            Size = new Size(292, 24), Location = new Point(14, 40), ForeColor = Color.DimGray,
        });
        var bar = new ProgressBar
        {
            Style = ProgressBarStyle.Marquee, MarqueeAnimationSpeed = 30,
            Location = new Point(14, 74), Size = new Size(292, 14),
        };
        _body.Controls.Add(bar);
    }

    private void AddFooter(int y)
    {
        var recordings = new LinkLabel
        {
            Text = "Recordings", AutoSize = true, Location = new Point(14, y + 4),
        };
        recordings.Click += (_, _) => OpenSaveFolder();

        var settings = new Button
        {
            Text = "⚙", Location = new Point(270, y), Size = new Size(36, 26), FlatStyle = FlatStyle.Flat,
        };
        settings.Click += (_, _) =>
        {
            using var f = new SettingsForm(_settings, _summarizer);
            f.ShowDialog(this);
            Render();
        };

        if (_phase == Phase.Done)
        {
            _body.Controls.Add(new Label
            {
                Text = "✓ Saved", ForeColor = Color.Green, AutoSize = true,
                Location = new Point(120, y + 4),
            });
        }

        _body.Controls.Add(recordings);
        _body.Controls.Add(settings);
    }

    // ---- actions ----

    private async Task StartAsync()
    {
        if (!Ready) { _status = "Finish setup first."; Render(); return; }
        try
        {
            _controller.OnLog = msg => BeginInvoke(() => { _status = msg; });
            _controller.Start(_settings.SelectedMicId, _settings.MicOnly);
            _phase = Phase.Recording;
            _status = "";
            Render();
        }
        catch (Exception e)
        {
            _phase = Phase.Error;
            _status = $"Couldn't start recording: {e.Message}";
            Render();
        }
        await Task.CompletedTask;
    }

    private async Task StopAsync()
    {
        _elapsedTimer?.Stop();
        _elapsedTimer?.Dispose();
        _elapsedTimer = null;

        var token = CredentialStore.Get();
        if (token == null) { _phase = Phase.Error; _status = "No token set."; Render(); return; }
        var config = OpenAIConfig.FromToken(AppConfig.ApiBaseUrl, token);
        var language = LanguageOption.ForId(_settings.LanguageId).Code;

        _phase = Phase.Transcribing;
        Render();

        // The name prompt runs synchronously on the UI thread while transcription proceeds.
        var outcome = await _controller.StopAndTranscribeAsync(
            config, language, promptForTitle: NameDialog.Prompt);

        _phase = outcome.Success ? Phase.Done : Phase.Error;
        _status = outcome.Status;
        _lastTranscript = outcome.TranscriptPath;
        Render();

        // Fade "Saved ✓" back to idle after a few seconds, like the macOS app.
        if (outcome.Success)
        {
            var t = new System.Windows.Forms.Timer { Interval = 4500 };
            t.Tick += (_, _) =>
            {
                t.Stop(); t.Dispose();
                if (_phase == Phase.Done) { _phase = Phase.Idle; Render(); }
            };
            t.Start();
        }
    }

    private void OpenSaveFolder()
    {
        try
        {
            Directory.CreateDirectory(_settings.SaveFolder);
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
            {
                FileName = _settings.SaveFolder, UseShellExecute = true,
            });
        }
        catch { /* ignore */ }
    }

    // ---- helpers ----

    private static Label MakeHeader(string text) => new()
    {
        Text = text, AutoSize = true, Location = new Point(14, 14),
        Font = new Font("Segoe UI", 11F, FontStyle.Bold),
    };

    private static Label MakeRowLabel(string text, int y) => new()
    {
        Text = text, AutoSize = false, Size = new Size(60, 20),
        Location = new Point(14, y), ForeColor = Color.DimGray,
    };

    private static void SelectComboById(ComboBox combo, string? id)
    {
        for (var i = 0; i < combo.Items.Count; i++)
        {
            if (combo.Items[i] is ComboItem c && c.Id == id) { combo.SelectedIndex = i; return; }
        }
        if (combo.Items.Count > 0) combo.SelectedIndex = 0;
    }

    private sealed record ComboItem(string? Id, string Name)
    {
        public override string ToString() => Name;
    }
}
