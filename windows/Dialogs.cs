using WordRelay.Core;

namespace WordRelay;

internal sealed class SettingsWindow : Form
{
    private readonly NumericUpDown count, minimum, customLimit, turn, end;
    private readonly TextBox custom;
    private readonly CheckBox top, track, suffix;
    private readonly Label status;
    public Settings Value { get; private set; }

    public SettingsWindow(Settings settings, bool shortcutConflict)
    {
        Value = settings;
        Text = "Word Relay settings";
        StartPosition = FormStartPosition.CenterParent;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = MinimizeBox = ShowInTaskbar = false;
        ClientSize = new Size(486, 503);
        BackColor = Theme.Canvas;
        ForeColor = Theme.Text;
        Font = Theme.Ui(10);
        AutoScaleMode = AutoScaleMode.Dpi;

        var content = new TableLayoutPanel
        {
            Dock = DockStyle.Fill, Padding = new Padding(17), ColumnCount = 2, RowCount = 13
        };
        content.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 70));
        content.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 30));
        foreach (int height in new[] { 31, 30, 30, 30, 30, 30, 27, 27, 27, 28, 0, 40, 40 })
            content.RowStyles.Add(height > 0 ? new RowStyle(SizeType.Absolute, height) : new RowStyle(SizeType.Percent, 100));
        Control Wide(Control widget, int row)
        {
            widget.Dock = DockStyle.Fill;
            content.Controls.Add(widget, 0, row);
            content.SetColumnSpan(widget, 2);
            return widget;
        }
        NumericUpDown Number(string label, int row, int value, int min, int max)
        {
            var caption = Theme.Label(label);
            caption.Dock = DockStyle.Fill;
            content.Controls.Add(caption, 0, row);
            var number = new NumericUpDown
            {
                Minimum = min, Maximum = max, Value = Math.Clamp(value, min, max),
                BackColor = Theme.Panel, ForeColor = Theme.Text, Dock = DockStyle.Fill, AccessibleName = label,
                TextAlign = HorizontalAlignment.Right
            };
            content.Controls.Add(number, 1, row);
            return number;
        }

        Wide(Theme.Label("Suggestions and timing", 14, true), 0);
        count = Number("Words per batch", 1, settings.Count, 1, 100);
        customLimit = Number("Custom words per batch", 2, settings.CustomLimit, 0, 100);
        minimum = Number("Minimum word length", 3, settings.MinLength, 2, 8);
        turn = Number("Fallback timer in seconds", 4, settings.TurnSeconds, 1, 120);
        end = Number("Match reset without tiles in seconds", 5, settings.EndSeconds, 5, 120);
        top = new CheckBox { Text = "Keep Word Relay above other windows", Checked = settings.Topmost };
        track = new CheckBox { Text = "Track my typed submissions in Roblox", Checked = settings.TrackWords };
        Wide(top, 6);
        Wide(track, 7);
        suffix = new CheckBox { Text = "Type only the letters after the prompt", Checked = settings.SkipTypedPrefix };
        Wide(suffix, 8);
        Wide(Theme.Label("Custom words (up to 100)", 10, true), 9);
        custom = Theme.Field("One word per line, or separated with commas");
        custom.Multiline = true;
        custom.ScrollBars = ScrollBars.Vertical;
        custom.Text = string.Join(Environment.NewLine, settings.Custom ?? []);
        custom.AccessibleName = "Custom words";
        Wide(custom, 10);
        status = Theme.Label(shortcutConflict ? "One or more global shortcuts are already in use." :
            "Start Ctrl+Shift+S   ·   Stop Ctrl+Shift+D   ·   New Ctrl+Shift+N\nType an answer on your turn with Ctrl+Shift+W", 8, false, Theme.Dim);
        Wide(status, 11);

        var buttons = Theme.Row(FlowDirection.RightToLeft);
        var save = Theme.Button("Save", (_, _) => Apply(), true);
        var cancel = Theme.Button("Cancel", (_, _) => { DialogResult = DialogResult.Cancel; Close(); });
        buttons.Controls.AddRange([save, cancel]);
        AcceptButton = save;
        CancelButton = cancel;
        Wide(buttons, 12);
        Controls.Add(content);
    }

    private void Apply()
    {
        var words = SuggestionOptions.ParseCustom(custom.Text);
        if (words.Count > 100)
        {
            status.Text = $"Remove {words.Count - 100} custom words before saving.";
            status.ForeColor = Theme.Warm;
            return;
        }
        Value = new Settings((int)count.Value, (int)minimum.Value, (int)customLimit.Value, words,
            (int)turn.Value, (int)end.Value, top.Checked, track.Checked, suffix.Checked);
        DialogResult = DialogResult.OK;
        Close();
    }
}

internal sealed class HistoryWindow : Form
{
    private readonly Match match;
    private readonly ListBox played = List("Played words");
    private readonly ListBox shown = List("Shown words");
    private readonly TextBox entry = Theme.Field("Word you played");
    private readonly Button undo;

    public HistoryWindow(Match match)
    {
        this.match = match;
        Text = "Match history";
        StartPosition = FormStartPosition.CenterParent;
        ClientSize = new Size(415, 427);
        MinimumSize = new Size(390, 380);
        ShowInTaskbar = false;
        BackColor = Theme.Canvas;
        ForeColor = Theme.Text;
        Font = Theme.Ui(10);
        AutoScaleMode = AutoScaleMode.Dpi;
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(14), RowCount = 4, ColumnCount = 1 };
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 29));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 39));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 39));
        var label = Theme.Label("Played and shown this match", 13, true);
        label.Dock = DockStyle.Fill;
        layout.Controls.Add(label, 0, 0);
        var tabs = new TabControl { Dock = DockStyle.Fill, AccessibleName = "History views" };
        var playedTab = new TabPage("Played") { BackColor = Theme.Panel };
        playedTab.Controls.Add(played);
        var shownTab = new TabPage("Shown") { BackColor = Theme.Panel };
        shownTab.Controls.Add(shown);
        tabs.TabPages.AddRange([playedTab, shownTab]);
        layout.Controls.Add(tabs, 0, 1);

        var manual = Theme.Row();
        entry.Width = 245;
        entry.MaxLength = 40;
        entry.Margin = new Padding(0, 7, 6, 0);
        entry.KeyDown += (_, e) => { if (e.KeyCode == Keys.Enter) { Add(); e.SuppressKeyPress = true; } };
        manual.Controls.AddRange([entry, Theme.Button("Mark played", (_, _) => Add())]);
        layout.Controls.Add(manual, 0, 2);
        var buttons = Theme.Row();
        undo = Theme.Button("Undo selected", (_, _) =>
        {
            if (played.SelectedItem is DisplayRow row) match.Undo(row.Word);
            UpdateLists();
        });
        played.SelectedIndexChanged += (_, _) => undo.Enabled = played.SelectedIndex >= 0;
        buttons.Controls.AddRange([undo, Theme.Button("Done", (_, _) => Close(), true)]);
        layout.Controls.Add(buttons, 0, 3);
        Controls.Add(layout);
        UpdateLists();
    }

    private static ListBox List(string label) => new()
    {
        Dock = DockStyle.Fill, BorderStyle = BorderStyle.None, BackColor = Theme.Panel, ForeColor = Theme.Text,
        AccessibleName = label, Font = Theme.Ui(11)
    };

    private void Add()
    {
        if (SuggestionOptions.Word(entry.Text) is not string word) return;
        match.Record(word, PlayedOrigin.Manual);
        entry.Clear();
        UpdateLists();
    }

    private void UpdateLists()
    {
        played.Items.Clear();
        played.Items.AddRange(match.PlayedWords.AsEnumerable().Reverse()
            .Select(word => new DisplayRow(word.Word, word.Origin)).Cast<object>().ToArray());
        shown.Items.Clear();
        shown.Items.AddRange(match.History.AsEnumerable().Reverse().Cast<object>().ToArray());
        undo.Enabled = played.SelectedIndex >= 0;
    }

    private sealed record DisplayRow(string Word, PlayedOrigin Origin)
    {
        public override string ToString() => $"{Word}  ·  {Origin switch
        {
            PlayedOrigin.Manual => "Marked manually",
            PlayedOrigin.Confirmed => "Submitted and seen",
            PlayedOrigin.Observed => "Seen on screen",
            PlayedOrigin.BoardAccepted => "Accepted on the board",
            _ => "Submitted"
        }}";
    }
}
