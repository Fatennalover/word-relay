using global::Android.Content;
using global::Android.Content.Res;
using global::Android.Graphics;
using global::Android.Graphics.Drawables;
using global::Android.Util;
using global::Android.Views;
using global::Android.Widget;

namespace WordRelay.Mobile;

internal static class RelayTheme
{
    internal static readonly Color Canvas = Color.Rgb(16, 25, 30);
    internal static readonly Color Panel = Color.Rgb(26, 42, 45);
    internal static readonly Color Edge = Color.Rgb(50, 76, 73);
    internal static readonly Color Text = Color.Rgb(230, 245, 239);
    internal static readonly Color Muted = Color.Rgb(158, 189, 177);
    internal static readonly Color Mint = Color.Rgb(174, 248, 212);
    internal static readonly Color Ink = Color.Rgb(10, 39, 31);
    internal static int Dp(Context context, int value) => (int)Math.Round(value * (context.Resources?.DisplayMetrics?.Density ?? 1));
    internal static GradientDrawable Card(Context context, Color color, int radius = 12, Color? stroke = null)
    {
        var shape = new GradientDrawable();
        shape.SetColor(color);
        shape.SetCornerRadius(Dp(context, radius));
        if (stroke.HasValue) shape.SetStroke(Dp(context, 1), stroke.Value);
        return shape;
    }

    internal static TextView Label(Context context, string value, float size = 15, Color? color = null, bool bold = false)
    {
        var text = new TextView(context) { Text = value, TextSize = size };
        text.SetTextColor(color ?? Text);
        if (bold) text.SetTypeface(null, TypefaceStyle.Bold);
        return text;
    }

    internal static Button Button(Context context, string value, Action click, bool primary = false)
    {
        var button = new Button(context)
        {
            Text = value, TextSize = 14,
            Gravity = GravityFlags.Center, Background = Card(context, primary ? Mint : Panel, 10, primary ? null : Edge)
        };
        button.SetAllCaps(false);
        button.SetMinHeight(Dp(context, 42));
        button.SetPadding(Dp(context, 12), Dp(context, 2), Dp(context, 12), Dp(context, 2));
        button.SetTextColor(primary ? Ink : Text);
        button.Click += (_, _) => click();
        return button;
    }

    internal static LinearLayout Stack(Context context, bool horizontal = false) =>
        new(context) { Orientation = horizontal ? global::Android.Widget.Orientation.Horizontal : global::Android.Widget.Orientation.Vertical };

    internal static LinearLayout Suggestion(Context context, string word, Action copy, Action mark, int height)
    {
        var row = Stack(context, true);
        var label = Button(context, word, copy);
        label.SetSingleLine();
        label.Gravity = GravityFlags.Left | GravityFlags.CenterVertical;
        label.LongClick += (_, e) => { mark(); e.Handled = true; };
        row.AddView(label, new LinearLayout.LayoutParams(0, Dp(context, height), 1));
        var played = Button(context, "✓", mark);
        played.ContentDescription = $"Mark {word} played";
        played.SetMinWidth(0);
        var size = new LinearLayout.LayoutParams(Dp(context, 42), Dp(context, height)) { LeftMargin = Dp(context, 4) };
        row.AddView(played, size);
        return row;
    }

    internal static void Gap(LinearLayout layout, Context context, int value) =>
        layout.AddView(new View(context), new LinearLayout.LayoutParams(-1, Dp(context, value)));

    internal static EditText Field(Context context, string hint, bool multiline = false)
    {
        var field = new EditText(context)
        {
            Hint = hint, TextSize = 15, Background = Card(context, Panel, 10, Edge)
        };
        field.SetSingleLine(!multiline);
        field.SetHintTextColor(Muted);
        field.SetTextColor(Text);
        field.SetPadding(Dp(context, 12), Dp(context, 8), Dp(context, 12), Dp(context, 8));
        return field;
    }
}
