using System.Buffers;
using global::Android.App;
using global::Android.Content;
using global::Android.Content.PM;
using global::Android.Graphics;
using global::Android.Hardware.Display;
using global::Android.Media;
using global::Android.Media.Projection;
using global::Android.OS;
using global::Android.Runtime;
using global::Android.Views;
using global::Android.Widget;
using WordRelay.Core;

namespace WordRelay.Mobile;

[Service(Name = "local.wordrelay.android.ProjectionService", Exported = false,
    ForegroundServiceType = ForegroundService.TypeMediaProjection)]
public sealed class ProjectionService : Service
{
    private const string Stop = "local.wordrelay.android.stop";
    private const string Channel = "tile-scanner";
    private readonly Handler ui = new(Looper.MainLooper!);
    private HandlerThread? worker;
    private Handler? background;
    private RelayStore store = null!;
    private TileReader reader = null!;
    private MediaProjection? projection;
    private ProjectionCallback? callback;
    private VirtualDisplay? display;
    private ImageReader? frames;
    private FloatingWords? floating;
    private volatile bool ending, contentVisible = true;
    private int density, currentWidth, currentHeight;
    private double nextFrame;

    public override IBinder? OnBind(Intent? intent) => null;

    public override void OnCreate()
    {
        base.OnCreate();
        store = RelayStore.Get(this);
        using var glyphs = Assets!.Open("glyphs.bin");
        reader = new TileReader(glyphs);
    }

    public override StartCommandResult OnStartCommand(Intent? intent, StartCommandFlags flags, int startId)
    {
        if (intent?.Action == Stop)
        {
            StopSelf();
            return StartCommandResult.NotSticky;
        }
        if (projection is not null) return StartCommandResult.NotSticky;

        StartNotification();
        var permission = OperatingSystem.IsAndroidVersionAtLeast(33)
            ? intent?.GetParcelableExtra("grant", Java.Lang.Class.FromType(typeof(Intent))) as Intent
            : intent?.GetParcelableExtra("grant") as Intent;
        if (permission is null || intent is null ||
            GetSystemService(MediaProjectionService) is not MediaProjectionManager manager)
        {
            store.SetScan(false, "Screen sharing permission is needed to start a scan.");
            StopSelf();
            return StartCommandResult.NotSticky;
        }

        try
        {
            worker = new HandlerThread("Word Relay OCR");
            worker.Start();
            background = new Handler(worker.Looper!);
            projection = manager.GetMediaProjection(intent.GetIntExtra("result", 0), permission);
            callback = new ProjectionCallback(this);
            projection!.RegisterCallback(callback, background);
            var metrics = Resources!.DisplayMetrics!;
            density = (int)metrics.DensityDpi;
            int width = metrics.WidthPixels, height = metrics.HeightPixels;
            if (OperatingSystem.IsAndroidVersionAtLeast(30) &&
                GetSystemService(WindowService)?.JavaCast<IWindowManager>() is { } managerWindow)
            {
                var bounds = managerWindow.MaximumWindowMetrics!.Bounds;
                width = bounds.Width();
                height = bounds.Height();
            }
            currentWidth = width;
            currentHeight = height;
            frames = NewReader(width, height);
            display = projection.CreateVirtualDisplay("Word Relay tiles", width, height, density,
                (DisplayFlags)VirtualDisplayFlags.AutoMirror, frames.Surface, null, background);
            if (display is null) throw new InvalidOperationException("Screen sharing display unavailable.");
            store.SetScan(true, "Scanning the shared app. You can switch to Roblox.");
            if (global::Android.Provider.Settings.CanDrawOverlays(this))
                floating = FloatingWords.TryShow(this, store, StopSelf);
        }
        catch (Exception error) when (error is Java.Lang.Exception or InvalidOperationException)
        {
            store.SetScan(false, "Screen sharing could not start. Try starting a new scan.");
            StopSelf();
        }
        return StartCommandResult.NotSticky;
    }

    private ImageReader NewReader(int width, int height)
    {
        var imageSource = ImageReader.NewInstance(width, height, (ImageFormatType)Format.Rgba8888, 2)!;
        imageSource.SetOnImageAvailableListener(new FrameListener(this), background);
        return imageSource;
    }

    private void StartNotification()
    {
        var manager = GetSystemService(NotificationService) as NotificationManager;
        manager?.CreateNotificationChannel(new NotificationChannel(Channel, "Word Relay scanner", NotificationImportance.Low));
        var stop = new Intent(this, typeof(ProjectionService)).SetAction(Stop);
        var stopButton = PendingIntent.GetService(this, 7, stop, PendingIntentFlags.Immutable | PendingIntentFlags.UpdateCurrent);
        var open = PendingIntent.GetActivity(this, 8, new Intent(this, typeof(MainActivity)),
            PendingIntentFlags.Immutable | PendingIntentFlags.UpdateCurrent);
        var actionIcon = global::Android.Graphics.Drawables.Icon.CreateWithResource(this, global::Android.Resource.Drawable.IcMenuCloseClearCancel);
        var action = new Notification.Action.Builder(actionIcon, new Java.Lang.String("Stop"), stopButton).Build();
        var notification = new Notification.Builder(this, Channel)
            .SetContentTitle("Word Relay is scanning")
            .SetContentText("Reads letter tiles from your selected screen.")
            .SetSmallIcon(global::Android.Resource.Drawable.IcMenuCamera)
            .SetContentIntent(open)
            .SetOngoing(true)
            .AddAction(action)
            .Build();
        if (OperatingSystem.IsAndroidVersionAtLeast(29))
            StartForeground(36, notification, ForegroundService.TypeMediaProjection);
        else StartForeground(36, notification);
    }

    private void CaptureFrame(ImageReader imageSource)
    {
        global::Android.Media.Image? frame = null;
        try
        {
            frame = imageSource.AcquireLatestImage();
            double now = RelayStore.Time;
            if (frame is null || ending || !contentVisible || now < nextFrame) return;
            nextFrame = now + .135;
            var plane = frame.GetPlanes()?[0];
            if (plane?.Buffer is not { } buffer || plane.PixelStride != 4) return;
            buffer.Rewind();
            int length = buffer.Remaining();
            int stride = plane.RowStride;
            if (length < stride * (frame.Height - 1) + frame.Width * 4) return;
            byte[] rented = ArrayPool<byte>.Shared.Rent(length);
            Reading reading;
            try
            {
                buffer.Get(rented, 0, length);
                var values = new int[frame.Width * frame.Height];
                for (int y = 0; y < frame.Height; y++)
                for (int x = 0; x < frame.Width; x++)
                {
                    int offset = y * stride + x * 4;
                    values[y * frame.Width + x] = unchecked((int)0xFF000000) |
                        rented[offset] << 16 | rented[offset + 1] << 8 | rented[offset + 2];
                }
                using var bitmap = Bitmap.CreateBitmap(values, frame.Width, frame.Height, Bitmap.Config.Argb8888!)!;
                reading = reader.Read(RelayStore.FromBitmap(bitmap, projection: true), ScanArea.Tiles);
            }
            finally { ArrayPool<byte>.Shared.Return(rented, clearArray: true); }
            ui.Post(() => { if (!ending && contentVisible) store.Read(reading); });
        }
        catch (Java.Lang.IllegalStateException) { }
        catch (Java.Lang.IllegalArgumentException) { }
        finally
        {
            frame?.Close();
            frame?.Dispose();
        }
    }

    private void Resize(int width, int height)
    {
        if (ending || display is null || width < 1 || height < 1 ||
            width == currentWidth && height == currentHeight) return;
        try
        {
            var replacement = NewReader(width, height);
            display.Surface = null;
            display.Resize(width, height, density);
            display.Surface = replacement.Surface;
            frames?.Close();
            frames = replacement;
            currentWidth = width;
            currentHeight = height;
        }
        catch (Java.Lang.IllegalStateException) { }
    }

    public override void OnDestroy()
    {
        ending = true;
        floating?.Dispose();
        if (store.Scanning) store.SetScan(false, "Screen scan stopped.");
        var currentProjection = projection;
        var currentCallback = callback;
        background?.Post(() =>
        {
            if (currentCallback is not null) currentProjection?.UnregisterCallback(currentCallback);
            display?.Release();
            frames?.Close();
            currentProjection?.Stop();
            worker?.QuitSafely();
        });
        StopForeground(StopForegroundFlags.Remove);
        base.OnDestroy();
    }

    private sealed class FrameListener(ProjectionService owner) : Java.Lang.Object, ImageReader.IOnImageAvailableListener
    {
        public void OnImageAvailable(ImageReader? source) { if (source is not null) owner.CaptureFrame(source); }
    }

    private sealed class ProjectionCallback(ProjectionService owner) : MediaProjection.Callback
    {
        public override void OnStop() => owner.ui.Post(owner.StopSelf);
        public override void OnCapturedContentResize(int width, int height) => owner.Resize(width, height);
        public override void OnCapturedContentVisibilityChanged(bool isVisible) => owner.contentVisible = isVisible;
    }
}

internal sealed class FloatingWords : IDisposable
{
    private readonly Service context;
    private readonly RelayStore store;
    private readonly IWindowManager manager;
    private readonly LinearLayout view, suggestions;
    private readonly TextView prompt, played;
    private readonly WindowManagerLayoutParams position;
    private int revision = -1;
    private float tapX, tapY;
    private int startX, startY;

    private FloatingWords(Service context, RelayStore store, IWindowManager manager, Action stop)
    {
        this.context = context;
        this.store = store;
        this.manager = manager;
        view = RelayTheme.Stack(context);
        view.Background = RelayTheme.Card(context, RelayTheme.Canvas, 15, RelayTheme.Edge);
        int pad = RelayTheme.Dp(context, 9);
        view.SetPadding(pad, pad, pad, pad);
        var header = RelayTheme.Stack(context, true);
        prompt = RelayTheme.Label(context, "WORD RELAY", 15, RelayTheme.Mint, true);
        prompt.Gravity = GravityFlags.CenterVertical;
        header.AddView(prompt, new LinearLayout.LayoutParams(0, -1, 1));
        var close = RelayTheme.Button(context, "×", stop);
        close.ContentDescription = "Stop screen scanner";
        header.AddView(close, new LinearLayout.LayoutParams(RelayTheme.Dp(context, 36), RelayTheme.Dp(context, 34)));
        view.AddView(header);
        played = RelayTheme.Label(context, "0 played", 11, RelayTheme.Muted);
        view.AddView(played);
        var scroll = new ScrollView(context);
        suggestions = RelayTheme.Stack(context);
        scroll.AddView(suggestions);
        view.AddView(scroll, new LinearLayout.LayoutParams(-1, RelayTheme.Dp(context, 154)));
        position = new WindowManagerLayoutParams(RelayTheme.Dp(context, 193), -2, WindowManagerTypes.ApplicationOverlay,
            WindowManagerFlags.NotFocusable | WindowManagerFlags.NotTouchModal, Format.Translucent)
        {
            Gravity = GravityFlags.Top | GravityFlags.Right, X = RelayTheme.Dp(context, 10), Y = RelayTheme.Dp(context, 72)
        };
        manager.AddView(view, position);
        prompt.Touch += (_, args) =>
        {
            if (args.Event is not { } e) return;
            if (e.Action == MotionEventActions.Down)
            {
                tapX = e.RawX; tapY = e.RawY; startX = position.X; startY = position.Y;
            }
            else if (e.Action == MotionEventActions.Move)
            {
                position.X = Math.Max(0, startX - (int)(e.RawX - tapX));
                position.Y = Math.Max(0, startY + (int)(e.RawY - tapY));
                manager.UpdateViewLayout(view, position);
            }
            args.Handled = true;
        };
        store.Changed += Update;
        Update();
    }

    public static FloatingWords? TryShow(Service context, RelayStore store, Action stop)
    {
        try
        {
            var manager = context.GetSystemService(Context.WindowService)?.JavaCast<IWindowManager>();
            return manager is null ? null : new FloatingWords(context, store, manager, stop);
        }
        catch (Java.Lang.SecurityException) { return null; }
    }

    public void Dispose()
    {
        store.Changed -= Update;
        manager.RemoveView(view);
    }

    private void Update()
    {
        if (revision == store.Match.Revision) return;
        revision = store.Match.Revision;
        prompt.Text = store.Match.Prefix.Length > 0 ? store.Match.Prefix.ToUpperInvariant() : "WORD RELAY";
        played.Text = $"{store.Match.UsedCount} played";
        suggestions.RemoveAllViews();
        if (store.Match.Suggestions.Count == 0)
            suggestions.AddView(RelayTheme.Label(context, store.Match.Prefix.Length == 0 ? "Waiting for tiles" : "No available matches", 12, RelayTheme.Muted));
        foreach (var word in store.Match.Suggestions)
        {
            suggestions.AddView(RelayTheme.Suggestion(context, word, () => RelayStore.Copy(context, word),
                () => store.Mark(word), 33));
        }
        if (store.Match.CanCycle) suggestions.AddView(RelayTheme.Button(context, "Next", store.Next));
    }
}
