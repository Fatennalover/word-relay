using global::Android.App;
using global::Android.Content;
using global::Android.Graphics;
using global::Android.Media.Projection;
using global::Android.OS;
using global::Android.Views;
using global::Android.Views.InputMethods;
using global::Android.Widget;
using WordRelay.Core;

namespace WordRelay.Mobile;

[Activity(Label = "Word Relay", Name = "local.wordrelay.android.MainActivity", MainLauncher = true, Exported = true)]
public sealed class MainActivity : Activity
{
    private const int SelectImage = 41, ShareScreen = 42;
    private RelayStore store = null!;
    private TextView prefix = null!, status = null!, stats = null!, clock = null!;
    private EditText input = null!;
    private LinearLayout words = null!;
    private Button capture = null!, next = null!;
    private int revision = -1;
    private readonly Handler ui = new(Looper.MainLooper!);
    private Java.Lang.Runnable? clockTicker;

    protected override void OnCreate(Bundle? state)
    {
        base.OnCreate(state);
        store = RelayStore.Get(this);
        if (!OperatingSystem.IsAndroidVersionAtLeast(35))
        {
            Window?.SetStatusBarColor(RelayTheme.Canvas);
            Window?.SetNavigationBarColor(RelayTheme.Canvas);
        }
        SetContentView(Build());
        clockTicker = new Java.Lang.Runnable(Tick);
        #if DEBUG
        if (Intent?.GetStringExtra("qa_prefix") is { Length: > 0 } sample) store.Lookup(sample);
        if (Intent?.GetStringExtra("qa_image") is { Length: > 0 } path) _ = OpenTestImage(path);
        #endif
    }

    protected override void OnStart()
    {
        base.OnStart();
        store.Changed += Refresh;
        Refresh();
        if (clockTicker is not null) ui.Post(clockTicker);
    }

    protected override void OnStop()
    {
        store.Changed -= Refresh;
        if (clockTicker is not null) ui.RemoveCallbacks(clockTicker);
        base.OnStop();
    }

    private View Build()
    {
        var scroll = new ScrollView(this);
        scroll.FillViewport = true;
        scroll.SetBackgroundColor(RelayTheme.Canvas);
        var stack = RelayTheme.Stack(this);
        int margin = RelayTheme.Dp(this, 18);
        stack.SetPadding(margin, margin, margin, margin);
        if (OperatingSystem.IsAndroidVersionAtLeast(30))
        {
            scroll.SetOnApplyWindowInsetsListener(new Insets(stack, margin));
        }
        scroll.AddView(stack);
        var header = RelayTheme.Stack(this, true);
        var icon = new ImageView(this);
        icon.SetImageResource(Resource.Mipmap.appicon);
        var iconSize = new LinearLayout.LayoutParams(RelayTheme.Dp(this, 51), RelayTheme.Dp(this, 51));
        iconSize.RightMargin = RelayTheme.Dp(this, 10);
        header.AddView(icon, iconSize);
        var title = RelayTheme.Stack(this);
        title.AddView(RelayTheme.Label(this, "Word Relay", 28, RelayTheme.Text, true));
        title.AddView(RelayTheme.Label(this, $"{store.Lexicon.Count:N0} English words", 12, RelayTheme.Muted));
        header.AddView(title, new LinearLayout.LayoutParams(0, -2, 1));
        header.AddView(RelayTheme.Button(this, "Settings", EditSettings));
        stack.AddView(header);
        RelayTheme.Gap(stack, this, 18);

        var prompt = RelayTheme.Stack(this);
        prompt.Background = RelayTheme.Card(this, RelayTheme.Panel, 17, RelayTheme.Edge);
        int padding = RelayTheme.Dp(this, 15);
        prompt.SetPadding(padding, padding, padding, padding);
        prompt.AddView(RelayTheme.Label(this, "CURRENT PREFIX", 11, RelayTheme.Muted, true));
        var display = RelayTheme.Stack(this, true);
        prefix = RelayTheme.Label(this, "—", 39, RelayTheme.Mint, true);
        prefix.Typeface = Typeface.Monospace;
        prefix.SetSingleLine();
        display.AddView(prefix, new LinearLayout.LayoutParams(0, -2, 1));
        clock = RelayTheme.Label(this, "—", 18, RelayTheme.Muted, true);
        clock.Gravity = GravityFlags.CenterVertical | GravityFlags.Right;
        display.AddView(clock, new LinearLayout.LayoutParams(-2, -1));
        prompt.AddView(display);
        stack.AddView(prompt);
        RelayTheme.Gap(stack, this, 13);

        var tools = RelayTheme.Stack(this, true);
        capture = RelayTheme.Button(this, "Start scan", Scan, true);
        AddButton(tools, capture);
        AddButton(tools, RelayTheme.Button(this, "Image", ChooseImage));
        AddButton(tools, RelayTheme.Button(this, "History", OpenHistory));
        stack.AddView(tools);
        RelayTheme.Gap(stack, this, 9);
        status = RelayTheme.Label(this, "Enter a prefix or share Roblox to scan.", 13, RelayTheme.Muted);
        stack.AddView(status);
        RelayTheme.Gap(stack, this, 13);

        var lookup = RelayTheme.Stack(this, true);
        input = RelayTheme.Field(this, "Enter starting letters");
        input.ImeOptions = ImeAction.Search;
        input.EditorAction += (_, e) =>
        {
            if (e.ActionId != ImeAction.Search) return;
            Find();
            e.Handled = true;
        };
        lookup.AddView(input, new LinearLayout.LayoutParams(0, RelayTheme.Dp(this, 42), 1));
        AddButton(lookup, RelayTheme.Button(this, "Find", Find, true));
        stack.AddView(lookup);
        RelayTheme.Gap(stack, this, 18);

        var titleRow = RelayTheme.Stack(this, true);
        var suggestionTitle = RelayTheme.Label(this, "Suggestions", 19, RelayTheme.Text, true);
        suggestionTitle.Gravity = GravityFlags.CenterVertical;
        titleRow.AddView(suggestionTitle, new LinearLayout.LayoutParams(0, -1, 1));
        next = RelayTheme.Button(this, "Next 5", () => store.Next());
        titleRow.AddView(next);
        stack.AddView(titleRow);
        RelayTheme.Gap(stack, this, 7);
        words = RelayTheme.Stack(this);
        stack.AddView(words);
        RelayTheme.Gap(stack, this, 14);
        var footer = RelayTheme.Stack(this, true);
        stats = RelayTheme.Label(this, "0 used · 0 shown", 12, RelayTheme.Muted);
        stats.Gravity = GravityFlags.CenterVertical;
        footer.AddView(stats, new LinearLayout.LayoutParams(0, -1, 1));
        footer.AddView(RelayTheme.Button(this, "New match", () => store.Reset()));
        stack.AddView(footer);
        return scroll;
    }

    private void AddButton(LinearLayout layout, Button button)
    {
        var size = new LinearLayout.LayoutParams(-2, RelayTheme.Dp(this, 42));
        if (layout.ChildCount > 0) size.LeftMargin = RelayTheme.Dp(this, 6);
        layout.AddView(button, size);
    }

    private void Find()
    {
        store.Lookup(input.Text ?? "");
        input.Text = "";
        if (GetSystemService(InputMethodService) is InputMethodManager keys)
            keys.HideSoftInputFromWindow(input.WindowToken, HideSoftInputFlags.None);
    }

    private void Tick()
    {
        var remaining = store.Match.Remaining(RelayStore.Time, store.Preferences.Turn);
        clock.Text = remaining.HasValue ? $"{remaining:0.0}s" : "—";
        if (clockTicker is not null) ui.PostDelayed(clockTicker, 220);
    }

    private void Refresh()
    {
        var match = store.Match;
        string message = store.Notice ?? match.FinishReason ?? (store.Scanning
            ? match.Phase == MatchPhase.Waiting ? "Scanning the shared app for starting tiles." : "Live scan active"
            : "Enter a prefix or import a screenshot.");
        status.Text = message;
        capture.Text = store.Scanning ? "Stop scan" : "Start scan";
        if (revision == match.Revision) return;
        revision = match.Revision;
        prefix.Text = match.Prefix.Length > 0 ? match.Prefix.ToUpperInvariant() : "—";
        prefix.TextSize = Math.Clamp(210f / Math.Max(1, match.Prefix.Length), 10f, 39f);
        stats.Text = $"{match.UsedCount} used · {match.History.Count} shown";
        next.Text = $"Next {store.Preferences.Count}";
        next.Enabled = match.CanCycle;
        words.RemoveAllViews();
        if (match.Suggestions.Count == 0)
            words.AddView(RelayTheme.Label(this, match.Prefix.Length == 0 ? "Your suggestions will appear here." : "No available matches for this prefix.", 14, RelayTheme.Muted));
        foreach (string word in match.Suggestions)
        {
            var tile = RelayTheme.Button(this, word, () =>
            {
                RelayStore.Copy(this, word);
                store.SetNotice($"Copied {word}");
            });
            tile.Gravity = GravityFlags.Left | GravityFlags.CenterVertical;
            tile.LongClick += (_, e) => { store.Mark(word); e.Handled = true; };
            var height = new LinearLayout.LayoutParams(-1, RelayTheme.Dp(this, 43));
            height.BottomMargin = RelayTheme.Dp(this, 5);
            words.AddView(tile, height);
        }
    }

    private void ChooseImage()
    {
        var doc = new Intent(Intent.ActionOpenDocument);
        doc.AddCategory(Intent.CategoryOpenable);
        doc.SetType("image/*");
        StartActivityForResult(doc, SelectImage);
    }

    private void Scan()
    {
        if (store.Scanning)
        {
            StopService(new Intent(this, typeof(ProjectionService)));
            return;
        }
        if (!global::Android.Provider.Settings.CanDrawOverlays(this))
        {
            new AlertDialog.Builder(this)
                .SetTitle("Show Word Relay over Roblox")
                .SetMessage("Enable display over other apps to see the floating suggestions while you play. Screenshot lookup is available from Image.")
                .SetNegativeButton("Continue without overlay", (_, _) => RequestCapture())
                .SetPositiveButton("Overlay settings", (_, _) => StartActivity(
                    new Intent(global::Android.Provider.Settings.ActionManageOverlayPermission,
                        global::Android.Net.Uri.Parse($"package:{PackageName}"))))
                .Show();
            return;
        }
        RequestCapture();
    }

    private void RequestCapture()
    {
        if (GetSystemService(MediaProjectionService) is MediaProjectionManager manager)
            StartActivityForResult(manager.CreateScreenCaptureIntent(), ShareScreen);
    }

    protected override async void OnActivityResult(int requestCode, Result resultCode, Intent? data)
    {
        base.OnActivityResult(requestCode, resultCode, data);
        if (resultCode != Result.Ok || data is null) return;
        if (requestCode == ShareScreen)
        {
            var command = new Intent(this, typeof(ProjectionService));
            command.PutExtra("grant", data);
            command.PutExtra("result", (int)resultCode);
            StartForegroundService(command);
        }
        else if (requestCode == SelectImage && data.Data is { } uri)
        {
            using var source = ContentResolver?.OpenInputStream(uri);
            if (source is not null) await ReadImage(source);
        }
    }

    private async Task ReadImage(Stream source)
    {
        store.SetNotice("Reading image…");
        try
        {
            using var buffer = new MemoryStream();
            await source.CopyToAsync(buffer);
            var bytes = buffer.ToArray();
            var reading = await Task.Run(() =>
            {
                using var image = BitmapFactory.DecodeByteArray(bytes, 0, bytes.Length);
                if (image is null) return default(Reading);
                using var glyphs = Assets!.Open("glyphs.bin");
                return new TileReader(glyphs).Read(RelayStore.FromBitmap(image), ScanArea.Tiles);
            });
            if (reading.Row is { } row)
            {
                store.Lookup(row, reading.Seconds);
                #if DEBUG
                global::Android.Util.Log.Info("WordRelayQA", $"prefix={row} count={store.Match.Suggestions.Count}");
                #endif
            }
            else store.SetNotice("No complete letter row found. Enter the starting letters to search.");
        }
        catch (Exception error) when (error is IOException or ArgumentException or Java.Lang.Exception)
        {
            store.SetNotice("That image could not be read.");
        }
    }

    #if DEBUG
    private async Task OpenTestImage(string path)
    {
        using var source = File.OpenRead(path);
        await ReadImage(source);
    }
    #endif

    private void EditSettings()
    {
        var old = store.Preferences;
        var fields = RelayTheme.Stack(this);
        int pad = RelayTheme.Dp(this, 15);
        fields.SetPadding(pad, pad, pad, pad);
        EditText Number(string title, int value)
        {
            fields.AddView(RelayTheme.Label(this, title, 13, RelayTheme.Muted));
            var field = RelayTheme.Field(this, title);
            field.InputType = global::Android.Text.InputTypes.ClassNumber;
            field.Text = value.ToString();
            fields.AddView(field);
            RelayTheme.Gap(fields, this, 9);
            return field;
        }
        var count = Number("Words per batch (1–100)", old.Count);
        var limit = Number("Custom words per batch (0–100)", old.Limit);
        var min = Number("Minimum word length (2–8)", old.Length);
        var turn = Number("Fallback turn timer in seconds", old.Turn);
        var end = Number("Match reset timeout in seconds", old.End);
        fields.AddView(RelayTheme.Label(this, "Custom words (up to 100)", 13, RelayTheme.Muted));
        var custom = RelayTheme.Field(this, "One word per line", true);
        custom.SetMinLines(4);
        custom.Text = string.Join("\n", old.Words ?? Array.Empty<string>());
        fields.AddView(custom);
        var scroll = new ScrollView(this);
        scroll.AddView(fields);
        var dialog = new AlertDialog.Builder(this).SetTitle("Word Relay settings").SetView(scroll)
            .SetPositiveButton("Save", (_, _) => { }).SetNegativeButton("Cancel", (_, _) => { }).Create()!;
        dialog.Show();
        dialog.GetButton((int)DialogButtonType.Positive)!.Click += (_, _) =>
        {
            int Value(EditText field, int fallback, int lower, int upper) =>
                int.TryParse(field.Text, out int value) ? Math.Clamp(value, lower, upper) : fallback;
            var list = SuggestionOptions.ParseCustom(custom.Text ?? "");
            if (list.Count > 100)
            {
                custom.Error = "Save up to 100 unique words.";
                return;
            }
            store.Save(new Preferences(Value(count, old.Count, 1, 100), Value(min, old.Length, 2, 8),
                Value(limit, old.Limit, 0, 100), Value(turn, old.Turn, 1, 120), Value(end, old.End, 5, 120), list));
            dialog.Dismiss();
        };
    }

    private void OpenHistory()
    {
        var view = RelayTheme.Stack(this);
        int pad = RelayTheme.Dp(this, 15);
        view.SetPadding(pad, pad, pad, pad);
        var entry = RelayTheme.Field(this, "Word played");
        view.AddView(entry);
        view.AddView(RelayTheme.Button(this, "Mark played", () =>
        {
            if (SuggestionOptions.Word(entry.Text ?? "") is not { } word) return;
            store.Mark(word);
            entry.Text = "";
            view.AddView(RelayTheme.Label(this, word, 14));
        }));
        view.AddView(RelayTheme.Label(this, "Played words (tap to undo)", 14, RelayTheme.Muted, true));
        foreach (var word in store.Match.PlayedWords.AsEnumerable().Reverse())
        {
            Button? button = null;
            button = RelayTheme.Button(this, word.Word, () => { store.Undo(word.Word); view.RemoveView(button); });
            view.AddView(button);
        }
        view.AddView(RelayTheme.Label(this, "Shown words", 14, RelayTheme.Muted, true));
        foreach (var word in store.Match.History.AsEnumerable().Reverse())
            view.AddView(RelayTheme.Label(this, word, 13));
        var scroller = new ScrollView(this);
        scroller.AddView(view);
        new AlertDialog.Builder(this).SetTitle("Match history").SetView(scroller)
            .SetPositiveButton("Done", (_, _) => { }).Show();
    }

    private sealed class Insets(View content, int extra) : Java.Lang.Object, View.IOnApplyWindowInsetsListener
    {
        public WindowInsets OnApplyWindowInsets(View? view, WindowInsets? insets)
        {
            if (insets is not null && OperatingSystem.IsAndroidVersionAtLeast(30))
            {
                var bars = insets.GetInsets(WindowInsets.Type.SystemBars() | WindowInsets.Type.DisplayCutout());
                content.SetPadding(extra + bars.Left, extra + bars.Top, extra + bars.Right, extra + bars.Bottom);
            }
            return insets!;
        }
    }
}
