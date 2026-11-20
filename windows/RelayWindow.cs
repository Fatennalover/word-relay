using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text.Json;
using WordRelay.Core;

namespace WordRelay;

internal static class Theme
{
    public static readonly Color Canvas = Color.FromArgb(17, 27, 31);
    public static readonly Color Panel = Color.FromArgb(26, 41, 45);
    public static readonly Color Edge = Color.FromArgb(54, 78, 80);
    public static readonly Color Text = Color.FromArgb(231, 245, 239);
    public static readonly Color Dim = Color.FromArgb(163, 188, 184);
    public static readonly Color Mint = Color.FromArgb(179, 248, 215);
    public static readonly Color Ink = Color.FromArgb(15, 47, 39);
    public static readonly Color Warm = Color.FromArgb(255, 196, 130);
    public static Font Ui(float size, FontStyle style = FontStyle.Regular) => new("Segoe UI", size, style);
    public static Font Mono(float size) => new("Consolas", size, FontStyle.Bold);

    public static Label Label(string text, float size = 10, bool bold = false, Color? color = null) => new()
    {
        Text = text, AutoSize = false, ForeColor = color ?? Text, Font = Ui(size, bold ? FontStyle.Bold : FontStyle.Regular),
        TextAlign = ContentAlignment.MiddleLeft, Margin = Padding.Empty, AutoEllipsis = true
    };

    public static Button Button(string text, EventHandler action, bool primary = false)
    {
        var button = new Button
        {
            Text = text, AutoSize = true, MinimumSize = new Size(0, 32),
            Padding = new Padding(8, 0, 8, 0), FlatStyle = FlatStyle.Flat,
            Font = Ui(9.5f, FontStyle.Bold), UseVisualStyleBackColor = false,
            BackColor = primary ? Mint : Panel, ForeColor = primary ? Ink : Text
        };
        button.FlatAppearance.BorderColor = primary ? Mint : Edge;
        button.Click += action;
        return button;
    }

    public static TextBox Field(string placeholder) => new()
    {
        PlaceholderText = placeholder, BorderStyle = BorderStyle.FixedSingle,
        BackColor = Panel, ForeColor = Text, Font = Ui(10)
    };

    public static FlowLayoutPanel Row(FlowDirection direction = FlowDirection.LeftToRight) => new()
    {
        FlowDirection = direction, WrapContents = false, Dock = DockStyle.Fill, Margin = Padding.Empty
    };
}

internal sealed record Settings(
    int Count = 5, int MinLength = 3, int CustomLimit = 100, List<string>? Custom = null, int TurnSeconds = 10,
    int EndSeconds = 30, bool Topmost = true, bool TrackWords = true)
{
    private static readonly string PathToFile = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "WordRelay", "settings.json");

    public SuggestionOptions Options => new(Math.Clamp(Count, 1, 100), Math.Clamp(MinLength, 2, 8),
        Math.Clamp(CustomLimit, 0, 100), Custom?.Where(word => SuggestionOptions.Word(word) is not null).Take(100).ToArray());

    public static Settings Load()
    {
        try
        {
            return JsonSerializer.Deserialize<Settings>(File.ReadAllText(PathToFile)) ?? new();
        }
        catch (IOException) { return new(); }
        catch (JsonException) { return new(); }
        catch (UnauthorizedAccessException) { return new(); }
    }

    public void Save()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(PathToFile)!);
        string temporary = PathToFile + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(this));
        File.Move(temporary, PathToFile, true);
    }
}

internal sealed class RelayWindow : Form
{
    private readonly Lexicon lexicon = new(Program.WordList("words.txt"), Program.WordList("words-extra.txt"));
    private readonly TileReader reader = new(Program.Asset("glyphs.bin"));
    private readonly System.Windows.Forms.Timer timer = new() { Interval = 100 };
    private readonly Settings initial = Settings.Load();
    private Settings preferences;
    private readonly Match match;
    private readonly SubmissionListener listener;
    private readonly Label prefix = Theme.Label("—", 33, true, Theme.Mint),
                           countDown = Theme.Label("—", 19, true, Theme.Mint),
                           clockCaption = Theme.Label("TURN TIMER", 8, false, Theme.Dim),
                           status = Theme.Label("Scanner off", 10, true, Theme.Dim),
                           note = Theme.Label("Click a suggestion to copy it.", 9, false, Theme.Dim);
    private Button run = null!, next = null!, history = null!, screenshot = null!;
    private readonly ListBox suggestions = new()
    {
        Dock = DockStyle.Fill, BorderStyle = BorderStyle.None,
        BackColor = Theme.Panel, ForeColor = Theme.Text, DrawMode = DrawMode.OwnerDrawFixed,
        IntegralHeight = false, AccessibleName = "Word suggestions", Font = Theme.Ui(12),
        Margin = Padding.Empty
    };
    private readonly TextBox input = Theme.Field("Enter starting letters");
    private GameWindow? game;
    private Reading lastFrame;
    private string? ownedClipboard;
    private uint clipboardSequence;
    private bool watching, busy, tracking, shortcutConflict, focusWasGame;
    private double lastFrameAt, nextFind, copyUntil, lastErrorUntil;
    private int generation, revision = -1;
    private string? copiedLabel;
    private string? errorLabel;

    internal RelayWindow()
    {
        preferences = initial;
        match = new Match(lexicon, preferences.Options);
        listener = new SubmissionListener(CanReadInput, PastedSuggestion, word => BeginInvoke(() => Submit(word)));
        Text = "Word Relay";
        AccessibleName = Text;
        MinimumSize = new Size(380, 590);
        ClientSize = new Size(406, 635);
        AutoScaleMode = AutoScaleMode.Dpi;
        BackColor = Theme.Canvas;
        ForeColor = Theme.Text;
        Font = Theme.Ui(10);
        using (var stockIcon = new Icon(Program.Asset("app.ico"))) Icon = (Icon)stockIcon.Clone();
        TopMost = preferences.Topmost;
        StartPosition = FormStartPosition.Manual;
        var screen = Screen.PrimaryScreen?.WorkingArea ?? SystemInformation.WorkingArea;
        Location = new Point(Math.Max(screen.Left, screen.Right - Width - 30), screen.Top + 38);
        Controls.Add(BuildLayout());
        timer.Tick += async (_, _) => await Tick();
        timer.Start();
        RefreshPresentation();
    }

    private Control BuildLayout()
    {
        var grid = new TableLayoutPanel
        {
            Dock = DockStyle.Fill, Padding = new Padding(19, 15, 19, 15),
            ColumnCount = 1, RowCount = 8, BackColor = Theme.Canvas
        };
        foreach (int height in new[] { 63, 108, 49, 34, 0, 35, 39, 38 })
            grid.RowStyles.Add(height == 0 ? new RowStyle(SizeType.Percent, 100f) : new RowStyle(SizeType.Absolute, height));
        grid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));

        var header = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 3, RowCount = 2, Margin = Padding.Empty };
        header.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 50));
        header.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        header.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        header.RowStyles.Add(new RowStyle(SizeType.Absolute, 33));
        header.RowStyles.Add(new RowStyle(SizeType.Absolute, 24));
        var picture = new PictureBox { Image = Icon!.ToBitmap(), SizeMode = PictureBoxSizeMode.Zoom, Size = new Size(39, 39),
            Margin = new Padding(0, 4, 10, 0), AccessibleName = "Word Relay logo" };
        header.Controls.Add(picture, 0, 0);
        header.SetRowSpan(picture, 2);
        header.Controls.Add(Docked(Theme.Label("Word Relay", 20, true)), 1, 0);
        header.Controls.Add(Docked(Theme.Label($"{lexicon.Count:N0} English words", 9, false, Theme.Dim)), 1, 1);
        var settings = Theme.Button("Settings", (_, _) => EditSettings());
        header.Controls.Add(settings, 2, 0);
        header.SetRowSpan(settings, 2);
        grid.Controls.Add(header, 0, 0);

        var hero = new TableLayoutPanel
        {
            Dock = DockStyle.Fill, BackColor = Theme.Panel, ColumnCount = 2, RowCount = 2,
            Margin = new Padding(0, 5, 0, 5), Padding = new Padding(15, 9, 14, 9)
        };
        hero.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 68));
        hero.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 32));
        hero.RowStyles.Add(new RowStyle(SizeType.Absolute, 23));
        hero.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        clockCaption.TextAlign = ContentAlignment.MiddleRight;
        countDown.TextAlign = ContentAlignment.MiddleRight;
        prefix.AccessibleName = "Current prefix";
        countDown.AccessibleName = "Remaining time";
        hero.Controls.Add(Docked(Theme.Label("CURRENT PREFIX", 8, true, Theme.Dim)), 0, 0);
        hero.Controls.Add(Docked(clockCaption), 1, 0);
        hero.Controls.Add(Docked(prefix), 0, 1);
        hero.Controls.Add(Docked(countDown), 1, 1);
        grid.Controls.Add(hero, 0, 1);

        var scanner = Theme.Row();
        run = Theme.Button("Start", (_, _) => { if (watching) StopScan(); else StartScan(); }, true);
        run.MinimumSize = new Size(82, 33);
        run.Margin = new Padding(0, 7, 9, 0);
        status.Margin = new Padding(0, 5, 0, 0);
        status.Size = new Size(254, 36);
        scanner.Controls.AddRange([run, status]);
        grid.Controls.Add(scanner, 0, 2);

        var labels = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, Margin = Padding.Empty };
        labels.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        labels.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        labels.Controls.Add(Docked(Theme.Label("Suggestions", 12, true)), 0, 0);
        next = Theme.Button("Next 5", (_, _) => { match.Next(); RefreshPresentation(); });
        next.MinimumSize = new Size(72, 27);
        next.Margin = Padding.Empty;
        labels.Controls.Add(next, 1, 0);
        grid.Controls.Add(labels, 0, 3);

        suggestions.ItemHeight = 32;
        suggestions.DrawItem += DrawWord;
        suggestions.MouseUp += (_, e) =>
        {
            int index = suggestions.IndexFromPoint(e.Location);
            if (index < 0) return;
            if (e.Button == MouseButtons.Right) suggestions.SelectedIndex = index;
            if (e.Button == MouseButtons.Left) CopySelected();
        };
        suggestions.KeyDown += (_, e) =>
        {
            if (e.KeyCode != Keys.Enter) return;
            CopySelected();
            e.SuppressKeyPress = true;
        };
        var actions = new ContextMenuStrip { BackColor = Theme.Panel, ForeColor = Theme.Text };
        actions.Items.Add("Mark played", null, (_, _) =>
        {
            if (suggestions.SelectedItem is string word)
            {
                match.Record(word, PlayedOrigin.Manual);
                RefreshPresentation();
            }
        });
        suggestions.ContextMenuStrip = actions;
        grid.Controls.Add(suggestions, 0, 4);
        grid.Controls.Add(Docked(note), 0, 5);

        var lookup = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 3, Margin = Padding.Empty };
        lookup.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        lookup.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        lookup.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        input.Dock = DockStyle.Fill;
        input.Margin = new Padding(0, 5, 6, 0);
        input.MaxLength = 40;
        input.KeyDown += (_, e) =>
        {
            if (e.KeyCode != Keys.Enter) return;
            Lookup();
            e.SuppressKeyPress = true;
        };
        lookup.Controls.Add(input, 0, 0);
        lookup.Controls.Add(Theme.Button("Find", (_, _) => Lookup()), 1, 0);
        screenshot = Theme.Button("Image…", async (_, _) => await ImportImage());
        lookup.Controls.Add(screenshot, 2, 0);
        grid.Controls.Add(lookup, 0, 6);

        var footer = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, Margin = Padding.Empty };
        footer.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        footer.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        history = Theme.Button("0 used · 0 shown", (_, _) => OpenHistory());
        history.Anchor = AnchorStyles.Left;
        history.Margin = Padding.Empty;
        footer.Controls.Add(history, 0, 0);
        footer.Controls.Add(Theme.Button("New match", (_, _) => NewMatch()), 1, 0);
        grid.Controls.Add(footer, 0, 7);
        return grid;
    }

    private static T Docked<T>(T control) where T : Control { control.Dock = DockStyle.Fill; return control; }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        Native.SetWindowDisplayAffinity(Handle, Native.ExcludeFromCapture);
        bool start = Native.RegisterHotKey(Handle, 1, Native.HotkeyModifiers, (uint)Keys.S);
        bool stop = Native.RegisterHotKey(Handle, 2, Native.HotkeyModifiers, (uint)Keys.D);
        bool restart = Native.RegisterHotKey(Handle, 3, Native.HotkeyModifiers, (uint)Keys.N);
        shortcutConflict = !(start && stop && restart);
    }

    protected override void OnHandleDestroyed(EventArgs e)
    {
        for (int i = 1; i <= 3; i++) Native.UnregisterHotKey(Handle, i);
        base.OnHandleDestroyed(e);
    }

    protected override void WndProc(ref Message message)
    {
        if (message.Msg == Native.HotkeyMessage)
        {
            switch ((int)message.WParam)
            {
                case 1: StartScan(); break;
                case 2: StopScan(); break;
                case 3: NewMatch(); break;
            }
        }
        base.WndProc(ref message);
    }

    private void StartScan()
    {
        if (watching) return;
        watching = true;
        generation++;
        game = null;
        nextFind = 0;
        match.Pause();
        RefreshTyping();
        RefreshPresentation();
    }

    private void StopScan()
    {
        watching = false;
        generation++;
        game = null;
        listener.Dispose();
        tracking = false;
        match.Pause();
        RefreshPresentation();
    }

    private void NewMatch()
    {
        listener.Clear();
        match.Reset();
        RefreshPresentation();
    }

    private void RefreshTyping()
    {
        listener.Dispose();
        tracking = watching && preferences.TrackWords && listener.Start();
    }

    private async Task Tick()
    {
        RefreshPresentation();
        if (!watching || busy) return;
        double now = Program.Time;
        if (game is not null && !game.Exists)
        {
            game = null;
            if (match.Phase != MatchPhase.Waiting) match.Reset();
        }
        if (game is null && now >= nextFind)
        {
            nextFind = now + 1.1;
            game = GameWindow.Find();
        }
        bool focused = game?.Foreground == true;
        if (focusWasGame && !focused) listener.Clear();
        focusWasGame = focused;
        if (!focused || game?.Bounds() is not { } bounds) return;

        busy = true;
        int source = generation;
        try
        {
            var reading = await Task.Run(() => reader.Read(FrameCapture.Screen(bounds), ScanArea.Tiles));
            if (!watching || source != generation || IsDisposed) return;
            if (game?.Foreground != true) return;
            lastFrame = reading;
            lastFrameAt = Program.Time;
            int turn = match.Turns;
            match.Observe(reading, lastFrameAt, Math.Clamp(preferences.EndSeconds, 5, 120));
            if (turn != match.Turns || match.Phase != MatchPhase.Turn) listener.Clear();
        }
        catch (Exception error) when (error is Win32Exception or ExternalException or ArgumentException)
        {
            Report("The game window could not be captured.");
        }
        finally { busy = false; }
        if (!IsDisposed) RefreshPresentation();
    }

    private bool CanReadInput() => watching && tracking && game?.Foreground == true &&
        match.Phase == MatchPhase.Turn && Program.Time - lastFrameAt <= .65 &&
        (lastFrame.Row is not null || match.ClockActive(Program.Time));

    private string? PastedSuggestion() => ownedClipboard is not null &&
        Native.GetClipboardSequenceNumber() == clipboardSequence ? ownedClipboard : null;

    private void Submit(string word)
    {
        if (!tracking || !watching || match.Phase != MatchPhase.Turn || !match.IsKnown(word)) return;
        var shownRow = lastFrame.Row?.ToLowerInvariant() ?? "";
        if (new[] { match.Prefix, match.PreviousPrefix, shownRow }.Any(p => p.Length > 0 && word.StartsWith(p, StringComparison.Ordinal)))
            match.Record(word, PlayedOrigin.Submitted);
        RefreshPresentation();
    }

    private void Lookup()
    {
        var entry = new string(input.Text.ToLowerInvariant().Where(char.IsAsciiLetter).Take(40).ToArray());
        if (entry.Length == 0) return;
        match.SetPrompt(entry, Program.Time);
        input.Clear();
        RefreshPresentation();
    }

    private async Task ImportImage()
    {
        using var dialog = new OpenFileDialog { Filter = "Images|*.png;*.jpg;*.jpeg;*.bmp", Title = "Read letter tiles from an image" };
        if (dialog.ShowDialog(this) != DialogResult.OK || watching) return;
        screenshot.Enabled = false;
        try
        {
            string file = dialog.FileName;
            var reading = await Task.Run(() =>
            {
                using var image = Image.FromFile(file);
                return reader.Read(FrameCapture.Image(image), ScanArea.Tiles);
            });
            if (watching || IsDisposed) return;
            if (reading.Row is { } row) match.SetPrompt(row, Program.Time, reading.Seconds);
            else Report("No complete tile row was found in that image.");
        }
        catch (Exception error) when (error is ArgumentException or IOException or ExternalException)
        {
            Report("That image could not be opened.");
        }
        if (!IsDisposed) RefreshPresentation();
    }

    private void CopySelected()
    {
        if (suggestions.SelectedItem is not string word) return;
        try
        {
            Clipboard.SetText(word);
            ownedClipboard = word;
            clipboardSequence = Native.GetClipboardSequenceNumber();
            copiedLabel = $"Copied {word}";
            copyUntil = Program.Time + 1.6;
        }
        catch (ExternalException) { Report("The clipboard is busy. Try copying again."); }
        RefreshPresentation();
    }

    private void DrawWord(object? sender, DrawItemEventArgs e)
    {
        if (e.Index < 0 || e.Index >= suggestions.Items.Count) return;
        var area = e.Bounds;
        bool active = (e.State & DrawItemState.Selected) != 0;
        using var background = new SolidBrush(active ? Color.FromArgb(48, 76, 70) : Theme.Panel);
        e.Graphics.FillRectangle(background, area);
        using var line = new Pen(Theme.Edge);
        e.Graphics.DrawLine(line, area.Left + 9, area.Bottom - 1, area.Right - 10, area.Bottom - 1);
        var textBox = new Rectangle(area.X + 11, area.Y, Math.Max(0, area.Width - 76), area.Height);
        var copyBox = new Rectangle(area.Right - 59, area.Y, 45, area.Height);
        var flags = TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis;
        TextRenderer.DrawText(e.Graphics, suggestions.Items[e.Index]?.ToString(), suggestions.Font, textBox, Theme.Text, flags);
        using var caption = Theme.Ui(8);
        TextRenderer.DrawText(e.Graphics, "Copy", caption, copyBox, Theme.Dim, flags | TextFormatFlags.Right);
    }

    private void RefreshPresentation()
    {
        double now = Program.Time;
        if (match.Revision != revision)
        {
            revision = match.Revision;
            suggestions.BeginUpdate();
            suggestions.Items.Clear();
            suggestions.Items.AddRange(match.Suggestions.Cast<object>().ToArray());
            suggestions.EndUpdate();
            prefix.Text = match.Prefix.Length > 0 ? match.Prefix.ToUpperInvariant() : "—";
            int letters = Math.Max(1, match.Prefix.Length);
            float scaled = Math.Clamp(220f / letters, 9f, 34f);
            if (Math.Abs(prefix.Font.Size - scaled) > .1)
            {
                var previous = prefix.Font;
                prefix.Font = Theme.Mono(scaled);
                previous.Dispose();
            }
            next.Enabled = match.CanCycle;
            history.Text = $"{match.UsedCount} used · {match.History.Count} shown";
        }
        next.Text = $"Next {preferences.Options.Count}";
        screenshot.Enabled = !watching && !busy;
        run.Text = watching ? "Stop" : "Start";
        var remaining = match.Remaining(now, Math.Clamp(preferences.TurnSeconds, 1, 120));
        countDown.Text = remaining is double seconds ? $"{seconds:0.0}s" : "—";
        countDown.ForeColor = remaining is < 3 ? Theme.Warm : Theme.Mint;
        clockCaption.Text = match.LiveSeconds.HasValue && remaining.HasValue ? "GAME CLOCK" : "TURN TIMER";
        status.Text = !watching ? "Scanner off" : game is null ? "Waiting for Roblox" :
            !focusWasGame ? "Focus Roblox to scan" : match.Phase switch
            {
                MatchPhase.Finished => "Match ended",
                MatchPhase.Waiting => "Waiting for starting tiles",
                MatchPhase.Between => "Waiting for tiles",
                _ => "Watching Roblox"
            };
        status.ForeColor = watching && focusWasGame ? Theme.Mint : Theme.Dim;
        note.ForeColor = now < lastErrorUntil ? Theme.Warm : Theme.Dim;
        note.Text = now < lastErrorUntil ? errorLabel : now < copyUntil ? copiedLabel :
            match.FinishReason ?? (match.Suggestions.Count == 0 && match.Prefix.Length > 0
                ? $"No available matches for {match.Prefix.ToUpperInvariant()}."
                : match.Suggestions.Count > 0 ? "Click to copy · right-click to mark played"
                : watching ? "Keep the Roblox window visible." : "Start scanning or enter the letters below.");
    }

    private void Report(string text) { errorLabel = text; lastErrorUntil = Program.Time + 3.5; }

    private void EditSettings()
    {
        using var dialog = new SettingsWindow(preferences, shortcutConflict);
        if (dialog.ShowDialog(this) != DialogResult.OK) return;
        preferences = dialog.Value;
        TopMost = preferences.Topmost;
        match.ApplyPreferences(preferences.Options);
        RefreshTyping();
        try { preferences.Save(); }
        catch (IOException) { Report("Settings are available until Word Relay closes."); }
        catch (UnauthorizedAccessException) { Report("Settings are available until Word Relay closes."); }
        RefreshPresentation();
    }

    private void OpenHistory()
    {
        using var dialog = new HistoryWindow(match);
        dialog.ShowDialog(this);
        RefreshPresentation();
    }

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        generation++;
        watching = false;
        timer.Dispose();
        listener.Dispose();
        base.OnFormClosed(e);
    }
}
