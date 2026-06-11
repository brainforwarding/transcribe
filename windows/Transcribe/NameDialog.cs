using System.Drawing;
using System.Windows.Forms;

namespace Transcribe.App;

/// <summary>
/// "Name this recording" modal: a single text field. Enter (Save) confirms; Escape or an empty
/// field (Skip) returns null. Mirrors the macOS promptForTitle — the caller falls back to the
/// timestamp name when null.
/// </summary>
public sealed class NameDialog : Form
{
    private readonly TextBox _field;

    private NameDialog()
    {
        Text = "Name this recording";
        FormBorderStyle = FormBorderStyle.FixedDialog;
        StartPosition = FormStartPosition.CenterScreen;
        MinimizeBox = false;
        MaximizeBox = false;
        ShowInTaskbar = false;
        TopMost = true;
        ClientSize = new Size(320, 110);

        var label = new Label
        {
            Text = "Optional name (Enter to save, Esc to skip):",
            AutoSize = true,
            Location = new Point(12, 12),
        };

        _field = new TextBox
        {
            Location = new Point(12, 38),
            Width = 296,
        };

        var save = new Button
        {
            Text = "Save",
            DialogResult = DialogResult.OK,
            Location = new Point(152, 72),
            Width = 75,
        };
        var skip = new Button
        {
            Text = "Skip",
            DialogResult = DialogResult.Cancel,
            Location = new Point(233, 72),
            Width = 75,
        };

        Controls.Add(label);
        Controls.Add(_field);
        Controls.Add(save);
        Controls.Add(skip);

        AcceptButton = save; // Enter
        CancelButton = skip; // Esc
        ActiveControl = _field;
    }

    /// <summary>Show the dialog and return the trimmed title, or null when skipped/empty.</summary>
    public static string? Prompt()
    {
        using var dlg = new NameDialog();
        var result = dlg.ShowDialog();
        if (result != DialogResult.OK) return null;
        var title = dlg._field.Text.Trim();
        return title.Length == 0 ? null : title;
    }
}
