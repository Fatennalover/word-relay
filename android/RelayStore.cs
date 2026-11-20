using System.Text.Json;
using global::Android.Content;
using global::Android.Graphics;
using global::Android.OS;
using WordRelay.Core;

namespace WordRelay.Mobile;

internal sealed record Preferences(int Count = 5, int Length = 3, int Limit = 100, int Turn = 10, int End = 30,
    IReadOnlyList<string>? Words = null)
{
    public SuggestionOptions Options => new(Math.Clamp(Count, 1, 100), Math.Clamp(Length, 2, 8),
        Math.Clamp(Limit, 0, 100), Words);
}

internal sealed class RelayStore
{
    private static RelayStore? instance;
    private readonly ISharedPreferences? storage;
    public static double Time => SystemClock.ElapsedRealtime() / 1000d;
    public static RelayStore Get(Context context) => instance ??= new RelayStore(context.ApplicationContext ?? context);

    internal Lexicon Lexicon { get; }
    internal Match Match { get; }
    internal Preferences Preferences { get; private set; }
    internal bool Scanning { get; private set; }
    internal string? Notice { get; private set; }
    internal event Action? Changed;

    private RelayStore(Context context)
    {
        storage = context.GetSharedPreferences("relay", FileCreationMode.Private);
        try { Preferences = JsonSerializer.Deserialize<Preferences>(storage?.GetString("settings", "{}") ?? "{}") ?? new(); }
        catch (JsonException) { Preferences = new(); }
        using var first = new StreamReader(context.Assets!.Open("words.txt"));
        using var expanded = new StreamReader(context.Assets.Open("words-extra.txt"));
        Lexicon = new Lexicon(first.ReadToEnd(), expanded.ReadToEnd());
        Match = new Match(Lexicon, Preferences.Options);
    }

    internal void Save(Preferences updated)
    {
        Preferences = updated;
        storage?.Edit()?.PutString("settings", JsonSerializer.Serialize(updated))?.Apply();
        Match.ApplyPreferences(updated.Options);
        Notify();
    }

    internal void SetScan(bool active, string? message)
    {
        Scanning = active;
        Notice = message;
        Match.Pause();
        Notify();
    }

    internal void Read(Reading frame)
    {
        if (!Scanning) return;
        int revision = Match.Revision;
        Match.Observe(frame, Time, Math.Clamp(Preferences.End, 5, 120));
        if (Match.Revision != revision || frame.Seconds.HasValue) Notify();
    }

    internal void Lookup(string text, double? seconds = null)
    {
        string word = new(text.ToLowerInvariant().Where(char.IsAsciiLetter).Take(40).ToArray());
        if (word.Length == 0) return;
        Notice = null;
        Match.SetPrompt(word, Time, seconds);
        Notify();
    }

    internal void Next() { Match.Next(); Notify(); }
    internal void Reset() { Notice = null; Match.Reset(); Notify(); }
    internal void Mark(string word) { Match.Record(word, PlayedOrigin.Manual); Notify(); }
    internal void Undo(string word) { Match.Undo(word); Notify(); }
    internal void SetNotice(string? message) { Notice = message; Notify(); }

    private void Notify() => Changed?.Invoke();

    internal static void Copy(Context context, string word)
    {
        if (context.GetSystemService(Context.ClipboardService) is ClipboardManager clipboard)
            clipboard.PrimaryClip = ClipData.NewPlainText("Word Relay", word);
    }

    internal static Raster FromBitmap(Bitmap image, bool projection = false)
    {
        using var content = projection ? TrimProjectionBars(image) : null;
        Bitmap source = content ?? image;
        Bitmap? scaled = null;
        try
        {
            if (source.Width > 1440)
                scaled = Bitmap.CreateScaledBitmap(source, 1440,
                    Math.Max(1, (int)Math.Round(source.Height * 1440d / source.Width)), true);
            source = scaled ?? source;
            var values = new int[source.Width * source.Height];
            source.GetPixels(values, 0, source.Width, 0, 0, source.Width, source.Height);
            var pixels = new byte[values.Length * 3];
            for (int i = 0; i < values.Length; i++)
            {
                int argb = values[i], p = i * 3;
                pixels[p] = (byte)(argb >> 16);
                pixels[p + 1] = (byte)(argb >> 8);
                pixels[p + 2] = (byte)argb;
            }
            return Raster.FromPixels(source.Width, source.Height, pixels, source.Width * 3, false);
        }
        finally { scaled?.Dispose(); }
    }

    private static Bitmap? TrimProjectionBars(Bitmap image)
    {
        int width = image.Width, height = image.Height;
        // Rotating a full-display share can leave a letterboxed image on the
        // virtual display. Look for symmetric, solid black margins first.
        var pixels = new int[width * height];
        image.GetPixels(pixels, 0, width, 0, 0, width, height);
        bool Black(int x, int y)
        {
            int rgba = pixels[y * width + x];
            return (rgba >> 16 & 255) < 16 && (rgba >> 8 & 255) < 16 && (rgba & 255) < 16;
        }
        bool BlackRow(int y) => Black(width / 6, y) && Black(width / 3, y) &&
            Black(width / 2, y) && Black(2 * width / 3, y) && Black(5 * width / 6, y);
        bool BlackColumn(int x) => Black(x, height / 6) && Black(x, height / 3) &&
            Black(x, height / 2) && Black(x, 2 * height / 3) && Black(x, 5 * height / 6);
        int top = 0, bottom = height - 1, left = 0, right = width - 1;
        while (top < height / 2 && BlackRow(top)) top++;
        while (bottom > height / 2 && BlackRow(bottom)) bottom--;
        if (top >= height * .06 && height - 1 - bottom >= height * .06 &&
            Math.Abs(top - (height - 1 - bottom)) <= height * .06 && bottom - top >= 220)
            return Bitmap.CreateBitmap(image, 0, top, width, bottom - top + 1);
        while (left < width / 2 && BlackColumn(left)) left++;
        while (right > width / 2 && BlackColumn(right)) right--;
        if (left >= width * .06 && width - 1 - right >= width * .06 &&
            Math.Abs(left - (width - 1 - right)) <= width * .06 && right - left >= 320)
            return Bitmap.CreateBitmap(image, left, 0, right - left + 1, height);
        return null;
    }
}
