using System.Diagnostics;
using System.Drawing;

namespace WordRelay.Core;

public readonly record struct Reading(string? Row, bool TilesPresent, bool ClockVisible,
    double? Seconds = null, int? Mistakes = null);

public sealed class TileReader
{
    private const int ShapeWidth = 20;
    private const int ShapeHeight = 24;
    private const int ShapeSize = ShapeWidth * ShapeHeight;
    private readonly record struct Shape(byte[] Pixels, double Aspect);
    private readonly record struct Template(char Letter, Shape Shape);
    private readonly record struct ClockFace(double X, double Y, double Radius);
    private readonly Template[] templates;
    private readonly Dictionary<string, char> memo = new();
    private double nextClockSample;

    public TileReader(Stream glyphs)
    {
        using var reader = new BinaryReader(glyphs);
        if (reader.ReadUInt32() != 0x31475257) throw new InvalidDataException("Invalid glyph file.");
        templates = new Template[reader.ReadUInt16()];
        for (int i = 0; i < templates.Length; i++)
        {
            char letter = (char)reader.ReadByte();
            double aspect = reader.ReadSingle();
            var pixels = reader.ReadBytes(ShapeSize);
            if (pixels.Length != ShapeSize) throw new EndOfStreamException();
            templates[i] = new Template(letter, new Shape(pixels, aspect));
        }
    }

    public Reading Read(Raster frame, ScanArea area)
    {
        var tiles = FindTiles(frame, area);
        var letters = new List<char>(tiles.Count);
        foreach (var tile in tiles)
        {
            var inset = (int)Math.Round(tile.Width * .085);
            var box = Rectangle.Inflate(tile, -inset, -inset);
            var shape = OutlineShape(frame.Slice(frame.Gray, box), box.Width, box.Height, 154, true);
            var letter = shape is { } glyph ? Classify(glyph, false) : '?';
            if (letter == '?') break;
            letters.Add(letter);
        }
        var clock = FindClock(frame);
        double now = Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency;
        double? seconds = null;
        if (clock is { } face && now >= nextClockSample)
        {
            nextClockSample = now + .25;
            seconds = ReadClock(frame, face);
        }
        var row = letters.Count > 0 && letters.Count == tiles.Count ? new string(letters.ToArray()) : null;
        return new Reading(row, tiles.Count > 0, clock.HasValue, seconds,
            clock.HasValue ? MistakeBadges(frame) : null);
    }

    private static List<Rectangle> FindTiles(Raster frame, ScanArea area)
    {
        var zone = area.Pixels(frame.Width, frame.Height);
        double target = frame.Height * .083;
        var candidates = new List<Rectangle>();
        foreach (var part in Geometry.Components(frame.Slice(frame.White, zone), zone.Width, zone.Height))
        {
            var b = part.Bounds;
            double fill = part.Pixels.Count / (double)(b.Width * b.Height);
            double aspect = b.Width / (double)b.Height;
            if (b.Height <= Math.Max(17, target * .45) || b.Height >= target * 1.72 ||
                aspect <= .77 || aspect >= 1.23 || fill <= .52 || fill >= .988 ||
                b.Left <= 0 || b.Top <= 0 || b.Right >= zone.Width || b.Bottom >= zone.Height) continue;
            b.Offset(zone.Location);
            if (DarkEdges(frame, b) >= 3) candidates.Add(b);
        }

        candidates.Sort((a, b) => a.Left.CompareTo(b.Left));
        var best = new List<Rectangle>();
        double bestScore = double.NegativeInfinity;
        double cx = zone.Left + zone.Width * .5, cy = zone.Top + zone.Height * .5;
        for (int start = 0; start < candidates.Count; start++)
        {
            var first = candidates[start];
            var row = new List<Rectangle> { first };
            var span = first;
            for (int i = start + 1; i < candidates.Count; i++)
            {
                var next = candidates[i];
                var last = row[^1];
                int gap = next.Left - last.Right;
                if (gap > last.Width * .46) break;
                if (gap < last.Width * .022 || Math.Abs(MidY(next) - MidY(last)) >= last.Height * .36 ||
                    Math.Abs(next.Height - last.Height) >= last.Height * .21) continue;
                row.Add(next);
                span = Rectangle.Union(span, next);
            }
            double center = (span.Left + span.Right) * .5;
            if (Math.Abs(center - cx) > first.Width * .47) continue;
            double score = (row.Count - 1) * .45 - Math.Abs(center - cx) / zone.Width * 4.5
                - Math.Abs(MidY(span) - cy) / zone.Height * 1.5 - Math.Abs(Math.Log(first.Height / target)) * .65;
            if (score <= bestScore) continue;
            bestScore = score;
            best = row;
        }
        return best;
    }

    private static int? MistakeBadges(Raster frame)
    {
        ReadOnlySpan<double> steps = [.101, .106, .111, .116, .121];
        ReadOnlySpan<double> offsetsX = [-.021, -.010, .010, .021];
        ReadOnlySpan<double> offsetsY = [-.015, 0, .015];
        double center = frame.Width * .5, height = frame.Height;
        int? result = null;
        int best = 0;
        for (int row = 0; row < 19; row++)
        {
            double y = (.854 + row * .0045) * height;
            foreach (double spacing in steps)
            {
                int marks = 0, strength = 0;
                bool foundInactive = false;
                for (int column = -2; column <= 2; column++)
                {
                    double x = center + column * spacing * height;
                    int muted = 0, active = 0;
                    foreach (double dy in offsetsY)
                    foreach (double dx in offsetsX)
                    {
                        int xx = (int)(x + dx * height), yy = (int)(y + dy * height);
                        if (xx < 0 || xx >= frame.Width || yy < 0 || yy >= frame.Height) continue;
                        byte badge = frame.Badge[yy * frame.Width + xx];
                        if (badge == 1) muted++;
                        if (badge == 2) active++;
                    }
                    if (active >= 6 && !foundInactive) { marks++; strength += active; }
                    else if (muted >= 7) { foundInactive = true; strength += muted; }
                    else { strength = 0; break; }
                }
                if (strength > best) { best = strength; result = marks; }
            }
        }
        return result;
    }

    private static double MidY(Rectangle r) => r.Top + r.Height * .5;

    private static int DarkEdges(Raster frame, Rectangle b)
    {
        int range = Math.Max(2, (int)(b.Width * .075));
        (int X, int Y, int Dx, int Dy)[] sides =
        [
            (b.X + b.Width / 3, b.Top, 0, -1), (b.X + b.Width * 2 / 3, b.Top, 0, -1),
            (b.X + b.Width / 3, b.Bottom - 1, 0, 1), (b.X + b.Width * 2 / 3, b.Bottom - 1, 0, 1),
            (b.Left, (int)MidY(b), -1, 0), (b.Right - 1, (int)MidY(b), 1, 0),
        ];
        int dark = 0;
        foreach (var side in sides)
        {
            for (int step = 1; step <= range; step++)
            {
                int x = side.X + side.Dx * step, y = side.Y + side.Dy * step;
                if (x >= 0 && y >= 0 && x < frame.Width && y < frame.Height && frame.Gray[y * frame.Width + x] < 96)
                {
                    dark++;
                    break;
                }
            }
        }
        return dark;
    }

    private static Shape? OutlineShape(byte[] gray, int width, int height, int threshold, bool letter)
    {
        var dark = new byte[gray.Length];
        for (int i = 0; i < dark.Length; i++) dark[i] = (byte)(gray[i] < threshold ? 1 : 0);
        var parts = Geometry.Components(dark, width, height).Where(p => p.Pixels.Count >= 3)
            .OrderByDescending(p => p.Pixels.Count).ToArray();
        if (parts.Length == 0) return null;
        var outer = parts[0];
        var bounds = outer.Bounds;
        if (letter && (bounds.Height <= height * .37 || bounds.Width <= width * .105)) return null;

        var filled = Geometry.FillContour(outer, width, height);
        var innerBounds = Rectangle.Inflate(bounds, -1, -1);
        foreach (var inner in parts.Skip(1).Where(part => innerBounds.Contains(part.Bounds)))
        {
            var hole = Geometry.FillContour(inner, width, height);
            foreach (int pixel in inner.Pixels) hole[pixel] = 0;
            for (int i = 0; i < filled.Length; i++)
                if (hole[i] == 1) filled[i] = 0;
        }
        return Normalize(filled, width, bounds);
    }

    private static Shape Normalize(byte[] mask, int width, Rectangle bounds)
    {
        var pixels = new byte[ShapeSize];
        double dx = bounds.Width / (double)ShapeWidth, dy = bounds.Height / (double)ShapeHeight;
        for (int y = 0; y < ShapeHeight; y++)
        for (int x = 0; x < ShapeWidth; x++)
        {
            int sy = bounds.Top + (int)((y + .5) * dy), sx = bounds.Left + (int)((x + .5) * dx);
            pixels[y * ShapeWidth + x] = mask[sy * width + sx];
        }
        return new Shape(pixels, bounds.Width / (double)bounds.Height);
    }

    private char Classify(Shape shape, bool digit)
    {
        string? key = digit ? null : Convert.ToBase64String(shape.Pixels) + Math.Round(shape.Aspect, 2);
        if (key is not null && memo.TryGetValue(key, out char cached)) return cached;
        var digitScores = digit ? new Dictionary<char, double>() : null;
        char best = '?';
        double distance = double.PositiveInfinity;
        foreach (var template in templates)
        {
            if (char.IsAsciiDigit(template.Letter) != digit) continue;
            double ratio = Math.Min(.5, Math.Abs(Math.Log(shape.Aspect / template.Shape.Aspect))) * .23;
            int mismatch = 0;
            for (int p = 0; p < ShapeSize; p++)
                if (shape.Pixels[p] != template.Shape.Pixels[p]) mismatch++;
            double score = mismatch / (double)ShapeSize + ratio;
            if (digitScores is not null && (!digitScores.TryGetValue(template.Letter, out double previous) || score < previous))
                digitScores[template.Letter] = score;
            if (score >= distance) continue;
            distance = score;
            best = template.Letter;
        }
        if (digitScores is not null)
        {
            double alternative = digitScores.Where(x => x.Key != best).Min(x => x.Value);
            if (distance > .30 || alternative - distance < .03) best = '?';
        }
        else if (distance > .33) best = '?';
        if (key is not null)
        {
            if (memo.Count >= 512) memo.Clear();
            memo[key] = best;
        }
        return best;
    }

    private static ClockFace? FindClock(Raster frame)
    {
        double centerX = frame.Width * .5;
        foreach (double y in new[] { .769, .758, .739, .783, .798 })
        foreach (double scale in new[] { .052, .047, .057 })
        {
            var centerY = frame.Height * y;
            double radius = frame.Height * scale;
            int white = 0;
            foreach (var point in new[] { (-.55, 0.0), (.55, 0.0), (0.0, -.49), (0.0, .52) })
                if (Sample(frame.White, frame, centerX + radius * point.Item1, centerY + radius * point.Item2)) white++;
            if (white < 3) continue;

            int blue = 0;
            for (int i = 0; i < 12; i++)
            {
                double angle = i * Math.PI / 6;
                foreach (double stretch in new[] { .85, .93, 1.01 })
                {
                    if (!Sample(frame.Blue, frame, centerX + Math.Cos(angle) * radius * stretch,
                                centerY + Math.Sin(angle) * radius * stretch)) continue;
                    blue++;
                    break;
                }
            }
            if (blue >= 7) return new ClockFace(centerX, centerY, radius);
        }
        return null;
    }

    private static bool Sample(byte[] values, Raster frame, double sx, double sy)
    {
        int x = (int)Math.Round(sx), y = (int)Math.Round(sy);
        return x >= 0 && y >= 0 && x < frame.Width && y < frame.Height && values[y * frame.Width + x] != 0;
    }

    private double? ReadClock(Raster frame, ClockFace face)
    {
        var crop = Rectangle.FromLTRB((int)(face.X - .64 * face.Radius), (int)(face.Y - .36 * face.Radius),
            (int)(face.X + .64 * face.Radius) + 1, (int)(face.Y + .48 * face.Radius) + 1);
        if (!new Rectangle(0, 0, frame.Width, frame.Height).Contains(crop)) return null;
        byte[] gray = frame.Slice(frame.Gray, crop);
        foreach (int threshold in new[] { 61, 76 })
        {
            var segments = new List<Rectangle>();
            int start = -1;
            for (int x = 0; x <= crop.Width; x++)
            {
                int ink = 0;
                if (x < crop.Width)
                    for (int y = 0; y < crop.Height; y++)
                        if (gray[y * crop.Width + x] < threshold) ink++;
                if (ink > 0)
                {
                    if (start < 0) start = x;
                }
                else if (start >= 0)
                {
                    int top = crop.Height, bottom = 0;
                    for (int row = 0; row < crop.Height; row++)
                    for (int col = start; col < x; col++)
                        if (gray[row * crop.Width + col] < threshold)
                        {
                            top = Math.Min(top, row);
                            bottom = Math.Max(bottom, row);
                        }
                    segments.Add(Rectangle.FromLTRB(start, top, x, bottom + 1));
                    start = -1;
                }
            }
            var text = new List<char>();
            foreach (var segment in segments)
            {
                if (segment.Height < face.Radius * .26)
                {
                    if (segment.Top >= crop.Height * .5 && segment.Width > 1) text.Add('.');
                    continue;
                }
                var glyphBox = Rectangle.Inflate(segment, 1, 1);
                glyphBox.Intersect(new Rectangle(0, 0, crop.Width, crop.Height));
                var glyph = new byte[glyphBox.Width * glyphBox.Height];
                for (int y = 0; y < glyphBox.Height; y++)
                    gray.AsSpan((glyphBox.Y + y) * crop.Width + glyphBox.X, glyphBox.Width)
                        .CopyTo(glyph.AsSpan(y * glyphBox.Width));
                char digit = OutlineShape(glyph, glyphBox.Width, glyphBox.Height, threshold, false) is { } shape
                    ? Classify(shape, true) : '?';
                text.Add(digit);
            }
            if (text.Count is 3 or 4 && text[^2] == '.' &&
                double.TryParse(new string(text.ToArray()), System.Globalization.CultureInfo.InvariantCulture, out double result) &&
                result is >= 0 and <= 90) return result;
        }
        return ReadConnectedClock(gray, crop.Width, crop.Height);
    }

    private double? ReadConnectedClock(byte[] gray, int width, int height)
    {
        const int threshold = 64;
        int top = height, bottom = -1;
        for (int y = 0; y < height; y++)
        for (int x = 0; x < width; x++)
        {
            if (gray[y * width + x] >= threshold) continue;
            top = Math.Min(top, y);
            bottom = y;
        }
        if (bottom - top < 10) return null;

        // The outlined decimal dot sometimes touches both digits. Find the
        // separation above it, then classify each digit in its own crop.
        int separatorHeight = top + (bottom - top) * 5 / 9;
        var groups = new List<(int Left, int Right)>();
        int start = -1;
        for (int x = 0; x <= width; x++)
        {
            bool ink = false;
            if (x < width)
                for (int y = top; y <= separatorHeight; y++)
                    ink |= gray[y * width + x] < threshold;
            if (ink && start < 0) start = x;
            if (!ink && start >= 0)
            {
                if (x - start >= 5) groups.Add((start, x));
                start = -1;
            }
        }
        if (groups.Count is not (2 or 3)) return null;

        int dot = (groups[^2].Right + groups[^1].Left) / 2;
        int lowerInk = 0;
        for (int y = separatorHeight + 1; y <= bottom; y++)
            if (gray[y * width + dot] < threshold) lowerInk++;
        if (lowerInk < 2) return null;

        var digits = new List<char>();
        for (int i = 0; i < groups.Count; i++)
        {
            int left = Math.Max(0, groups[i].Left - 2);
            int right = Math.Min(width, groups[i].Right + 2);
            if (i > 0) left = Math.Max(left, (groups[i - 1].Right + groups[i].Left) / 2);
            if (i + 1 < groups.Count) right = Math.Min(right, (groups[i].Right + groups[i + 1].Left) / 2);
            var digit = new byte[(right - left) * height];
            for (int y = 0; y < height; y++)
                gray.AsSpan(y * width + left, right - left).CopyTo(digit.AsSpan(y * (right - left)));
            digits.Add(OutlineShape(digit, right - left, height, threshold, false) is { } shape
                ? Classify(shape, true) : '?');
        }
        if (digits.Any(digit => digit == '?')) return null;
        double seconds = int.Parse(new string(digits.ToArray()), System.Globalization.CultureInfo.InvariantCulture) / 10d;
        return seconds <= 90 ? seconds : null;
    }
}
