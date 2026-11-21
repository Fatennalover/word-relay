using System.ComponentModel;
using System.Diagnostics;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;
using WordRelay.Core;

namespace WordRelay;

internal sealed record GameWindow(nint Handle, uint ProcessId)
{
    private static readonly string[] RobloxNames = ["RobloxPlayerBeta", "RobloxPlayer", "Roblox"];
    private static bool IsGame(int processId)
    {
        try
        {
            using var process = Process.GetProcessById(processId);
            return RobloxNames.Contains(process.ProcessName, StringComparer.OrdinalIgnoreCase);
        }
        catch (ArgumentException) { return false; }
        catch (InvalidOperationException) { return false; }
        catch (Win32Exception) { return false; }
    }

    public static GameWindow? Find()
    {
        GameWindow? best = null;
        long largest = 0;
        Native.EnumWindows((hwnd, _) =>
        {
            if (!Native.IsWindowVisible(hwnd) || Native.IsIconic(hwnd) ||
                !Native.GetClientRect(hwnd, out var box) || box.Right < 360 || box.Bottom < 230)
                return true;
            Native.GetWindowThreadProcessId(hwnd, out uint pid);
            if (pid == 0 || !IsGame((int)pid)) return true;
            long size = (long)box.Right * box.Bottom;
            if (size > largest)
            {
                largest = size;
                best = new GameWindow(hwnd, pid);
            }
            return true;
        }, 0);
        return best;
    }

    public bool Exists => Native.IsWindow(Handle) &&
        Native.GetWindowThreadProcessId(Handle, out uint pid) != 0 && pid == ProcessId;

    public bool Foreground => Native.GetForegroundWindow() == Handle && Exists;

    public Rectangle? Bounds()
    {
        if (!Exists || Native.IsIconic(Handle) || !Native.GetClientRect(Handle, out var client)) return null;
        var origin = new Native.Point();
        if (!Native.ClientToScreen(Handle, ref origin)) return null;
        var bounds = new Rectangle(origin.X, origin.Y, client.Right, client.Bottom);
        return bounds.Width >= 360 && bounds.Height >= 230 && SystemInformation.VirtualScreen.Contains(bounds)
            ? bounds : null;
    }
}

internal static class FrameCapture
{
    public static Raster Screen(Rectangle bounds)
    {
        using var raw = new Bitmap(bounds.Width, bounds.Height, PixelFormat.Format32bppRgb);
        using (var graphics = Graphics.FromImage(raw))
            graphics.CopyFromScreen(bounds.Location, Point.Empty, bounds.Size, CopyPixelOperation.SourceCopy);
        return Image(raw);
    }

    public static unsafe Raster Image(Image source)
    {
        int width = Math.Min(1440, source.Width);
        int height = Math.Max(1, (int)Math.Round(source.Height * width / (double)source.Width));
        using var scaled = new Bitmap(width, height, PixelFormat.Format32bppRgb);
        using (var graphics = Graphics.FromImage(scaled))
        {
            graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
            graphics.DrawImage(source, new Rectangle(0, 0, width, height));
        }
        var bits = scaled.LockBits(new Rectangle(0, 0, width, height), ImageLockMode.ReadOnly, PixelFormat.Format32bppRgb);
        try
        {
            if (bits.Stride > 0)
                return Raster.FromPixels(width, height, new ReadOnlySpan<byte>(bits.Scan0.ToPointer(),
                    bits.Stride * height), bits.Stride, true);
            var flattened = new byte[width * height * 4];
            for (int y = 0; y < height; y++)
                Marshal.Copy(bits.Scan0 + y * bits.Stride, flattened, y * width * 4, width * 4);
            return Raster.FromPixels(width, height, flattened, width * 4, true);
        }
        finally { scaled.UnlockBits(bits); }
    }
}

internal static partial class Native
{
    internal const int HotkeyMessage = 0x0312;
    internal const uint HotkeyModifiers = 0x0002 | 0x0004 | 0x4000;
    internal const int KeyboardHook = 13;
    internal const uint KeyDown = 0x0100;
    internal const uint SystemKeyDown = 0x0104;
    internal const uint ExcludeFromCapture = 0x11;

    [StructLayout(LayoutKind.Sequential)]
    internal struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    internal struct Point { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)]
    internal struct KeyboardData { public uint VirtualKey, ScanCode, Flags, Time; public nuint Extra; }
    [StructLayout(LayoutKind.Sequential)]
    internal struct Input { public uint Type; public InputData Data; }
    [StructLayout(LayoutKind.Explicit)]
    internal struct InputData
    {
        [FieldOffset(0)] public KeyboardInput Keyboard;
        [FieldOffset(0)] private MouseInput mouse;
    }
    [StructLayout(LayoutKind.Sequential)]
    internal struct KeyboardInput
    {
        public ushort Key, Scan;
        public uint Flags, Time;
        public nuint Extra;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct MouseInput
    {
        public int X, Y;
        public uint MouseData, Flags, Time;
        public nuint Extra;
    }

    internal delegate bool Enumerate(nint hwnd, nint data);
    internal delegate nint KeyboardCallback(int code, nuint message, nint data);

    [DllImport("user32.dll")] internal static extern bool EnumWindows(Enumerate callback, nint data);
    [DllImport("user32.dll")] internal static extern bool IsWindow(nint hwnd);
    [DllImport("user32.dll")] internal static extern bool IsWindowVisible(nint hwnd);
    [DllImport("user32.dll")] internal static extern bool IsIconic(nint hwnd);
    [DllImport("user32.dll")] internal static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] internal static extern uint GetWindowThreadProcessId(nint hwnd, out uint pid);
    [DllImport("user32.dll")] internal static extern bool GetClientRect(nint hwnd, out Rect rect);
    [DllImport("user32.dll")] internal static extern bool ClientToScreen(nint hwnd, ref Point position);
    [DllImport("user32.dll")] internal static extern bool SetWindowDisplayAffinity(nint hwnd, uint affinity);
    [DllImport("user32.dll")] internal static extern bool RegisterHotKey(nint hwnd, int id, uint modifiers, uint key);
    [DllImport("user32.dll")] internal static extern bool UnregisterHotKey(nint hwnd, int id);
    [DllImport("user32.dll")] internal static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll")] internal static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll", SetLastError = true)] internal static extern uint SendInput(uint count, Input[] inputs, int size);
    [DllImport("user32.dll", SetLastError = true)] internal static extern nint SetWindowsHookEx(int hook, KeyboardCallback callback, nint module, uint thread);
    [DllImport("user32.dll")] internal static extern bool UnhookWindowsHookEx(nint hook);
    [DllImport("user32.dll")] internal static extern nint CallNextHookEx(nint hook, int code, nuint message, nint data);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] internal static extern nint GetModuleHandle(string? name);
}

internal static class AnswerTyping
{
    internal const nuint EventTag = 0x57524C59;
    internal static bool ModifiersReleased => Native.GetAsyncKeyState(0x10) >= 0 &&
        Native.GetAsyncKeyState(0x11) >= 0 && Native.GetAsyncKeyState(0x12) >= 0 &&
        Native.GetAsyncKeyState(0x5B) >= 0 && Native.GetAsyncKeyState(0x5C) >= 0;

    internal static bool Type(string text, GameWindow game)
    {
        if (text.Length == 0 || !text.All(char.IsAsciiLetter) || !ModifiersReleased) return false;
        var keys = text.ToUpperInvariant().Select(c => (ushort)c).Append((ushort)0x0D);
        var inputs = keys.SelectMany(key => new[] { Press(key, 0), Press(key, 2) }).ToArray();
        return game.Foreground && Native.SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<Native.Input>()) == inputs.Length;
    }

    private static Native.Input Press(ushort key, uint flags) => new()
    {
        Type = 1,
        Data = new Native.InputData
        {
            Keyboard = new Native.KeyboardInput { Key = key, Flags = flags, Extra = EventTag }
        }
    };
}

internal sealed class SubmissionListener : IDisposable
{
    private readonly Func<bool> canRead;
    private readonly Func<string?> pasted;
    private readonly Action<string, bool> submit;
    private readonly Native.KeyboardCallback callback;
    private readonly StringBuilder draft = new(40);
    private nint hook;
    private int cursor;
    private bool selected, invalid, previousTurn;

    public SubmissionListener(Func<bool> canRead, Func<string?> pasted, Action<string, bool> submit)
    {
        this.canRead = canRead;
        this.pasted = pasted;
        this.submit = submit;
        callback = Observe;
    }

    public bool Start()
    {
        if (hook != 0) return true;
        hook = Native.SetWindowsHookEx(Native.KeyboardHook, callback, Native.GetModuleHandle(null), 0);
        return hook != 0;
    }

    public void Clear()
    {
        draft.Clear();
        cursor = 0;
        selected = invalid = previousTurn = false;
    }

    public void TurnChanged()
    {
        if (previousTurn) Clear();
        previousTurn = true;
    }

    public void Dispose()
    {
        if (hook != 0) Native.UnhookWindowsHookEx(hook);
        hook = 0;
        Clear();
    }

    private nint Observe(int code, nuint message, nint data)
    {
        if (code >= 0 && message is Native.KeyDown or Native.SystemKeyDown)
        {
            var input = Marshal.PtrToStructure<Native.KeyboardData>(data);
            if (input.Extra != AnswerTyping.EventTag)
            {
                if (canRead()) Key((int)input.VirtualKey);
                else Clear();
            }
        }
        return Native.CallNextHookEx(hook, code, message, data);
    }

    private static bool Down(int key) => Native.GetAsyncKeyState(key) < 0;

    private void Key(int key)
    {
        if (previousTurn && key != 0x0D) Clear();
        if (Down(0x12) || Down(0x5B) || Down(0x5C)) return;
        if (Down(0x11))
        {
            switch (key)
            {
                case 0x41: selected = true; break;
                case 0x56:
                    if (pasted() is { } value) Insert(value);
                    else Clear();
                    break;
                case 0x58: Clear(); break;
            }
            return;
        }
        if (key is >= 0x41 and <= 0x5A) { Insert(((char)key).ToString()); return; }
        switch (key)
        {
            case 0x0D:
                string? word = invalid || draft.Length == 0 ? null : draft.ToString();
                bool fromPreviousTurn = previousTurn;
                Clear();
                if (word is not null) submit(word, fromPreviousTurn);
                break;
            case 0x08:
                if (selected) Clear();
                else if (cursor > 0) draft.Remove(--cursor, 1);
                break;
            case 0x2E:
                if (selected) Clear();
                else if (cursor < draft.Length) draft.Remove(cursor, 1);
                break;
            case 0x25: cursor = Math.Max(0, cursor - 1); selected = false; break;
            case 0x27: cursor = Math.Min(draft.Length, cursor + 1); selected = false; break;
            case 0x24: cursor = 0; selected = false; break;
            case 0x23: cursor = draft.Length; selected = false; break;
            case 0x09: case 0x1B: Clear(); break;
            case 0x20: case 0xBF: case >= 0x30 and <= 0x39: Clear(); invalid = true; break;
        }
    }

    private void Insert(string word)
    {
        if (selected) Clear();
        if (invalid) return;
        if (draft.Length + word.Length > 40) { Clear(); invalid = true; return; }
        draft.Insert(cursor, word.ToLowerInvariant());
        cursor += word.Length;
    }
}
