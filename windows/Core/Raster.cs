using System.Drawing;

namespace WordRelay.Core;

public readonly record struct ScanArea(double X, double Y, double Width, double Height)
{
    public static readonly ScanArea Tiles = new(.045, .28, .91, .24);

    public Rectangle Pixels(int width, int height) => Rectangle.Intersect(
        new Rectangle(0, 0, width, height),
        Rectangle.FromLTRB((int)(X * width), (int)(Y * height),
            (int)Math.Ceiling((X + Width) * width), (int)Math.Ceiling((Y + Height) * height)));
}

public sealed class Raster
{
    public readonly int Width;
    public readonly int Height;
    public readonly byte[] Gray;
    public readonly byte[] White;
    public readonly byte[] Blue;

    private Raster(int width, int height, byte[] gray, byte[] white, byte[] blue)
    {
        Width = width;
        Height = height;
        Gray = gray;
        White = white;
        Blue = blue;
    }

    public static Raster FromPixels(int width, int height, ReadOnlySpan<byte> pixels, int stride, bool bgra)
    {
        var gray = new byte[width * height];
        var white = new byte[gray.Length];
        var blue = new byte[gray.Length];
        int pixelSize = bgra ? 4 : 3;
        for (int y = 0; y < height; y++)
        {
            var row = pixels.Slice(y * stride, width * pixelSize);
            for (int x = 0; x < width; x++)
            {
                int src = x * pixelSize, dst = y * width + x;
                int r = row[src + (bgra ? 2 : 0)], g = row[src + 1], b = row[src + (bgra ? 0 : 2)];
                gray[dst] = (byte)((77 * r + 150 * g + 29 * b) >> 8);
                int low = Math.Min(r, Math.Min(g, b));
                white[dst] = (byte)(low >= 224 && Math.Max(r, Math.Max(g, b)) - low < 23 ? 1 : 0);
                blue[dst] = (byte)(b >= 163 && g >= 112 && b - r >= 24 && b - g >= 12 ? 1 : 0);
            }
        }
        return new Raster(width, height, gray, white, blue);
    }

    public byte[] Slice(byte[] channel, Rectangle bounds)
    {
        var result = new byte[bounds.Width * bounds.Height];
        for (int y = 0; y < bounds.Height; y++)
            channel.AsSpan((bounds.Y + y) * Width + bounds.X, bounds.Width)
                .CopyTo(result.AsSpan(y * bounds.Width));
        return result;
    }
}

internal sealed record Component(Rectangle Bounds, List<int> Pixels);

internal static class Geometry
{
    public static IEnumerable<Component> Components(byte[] image, int width, int height)
    {
        var remaining = (byte[])image.Clone();
        for (int index = 0; index < remaining.Length; index++)
        {
            if (remaining[index] == 0) continue;
            remaining[index] = 0;
            var queue = new List<int> { index };
            int left = width, top = height, right = 0, bottom = 0;
            for (int head = 0; head < queue.Count; head++)
            {
                int p = queue[head], x = p % width, y = p / width;
                left = Math.Min(left, x);
                top = Math.Min(top, y);
                right = Math.Max(right, x);
                bottom = Math.Max(bottom, y);
                AddNeighbors(queue, remaining, width, height, p, x, y);
            }
            yield return new Component(Rectangle.FromLTRB(left, top, right + 1, bottom + 1), queue);
        }
    }

    public static byte[] FillContour(Component contour, int width, int height)
    {
        var inside = new byte[width * height];
        Array.Fill(inside, (byte)1);
        foreach (int p in contour.Pixels) inside[p] = 0;
        var queue = new List<int>();
        for (int x = 0; x < width; x++)
        {
            Enqueue(queue, inside, x);
            Enqueue(queue, inside, (height - 1) * width + x);
        }
        for (int y = 1; y < height - 1; y++)
        {
            Enqueue(queue, inside, y * width);
            Enqueue(queue, inside, y * width + width - 1);
        }
        for (int head = 0; head < queue.Count; head++)
        {
            int p = queue[head];
            AddNeighbors(queue, inside, width, height, p, p % width, p / width);
        }
        foreach (int p in contour.Pixels) inside[p] = 1;
        return inside;
    }

    private static void AddNeighbors(List<int> queue, byte[] mask, int width, int height, int p, int x, int y)
    {
        if (x > 0) Enqueue(queue, mask, p - 1);
        if (x < width - 1) Enqueue(queue, mask, p + 1);
        if (y > 0) Enqueue(queue, mask, p - width);
        if (y < height - 1) Enqueue(queue, mask, p + width);
    }

    private static void Enqueue(List<int> queue, byte[] mask, int p)
    {
        if (mask[p] == 0) return;
        mask[p] = 0;
        queue.Add(p);
    }
}
