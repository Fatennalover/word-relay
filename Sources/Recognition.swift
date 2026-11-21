#if os(macOS)
import AppKit
#else
import Foundation
import CoreGraphics
import CoreVideo
#endif
import CoreMedia
import CoreText
import Vision

struct ScanRegion: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    static let previousTiles = ScanRegion(x: 0.25, y: 0.265, width: 0.50, height: 0.30)
    static let tiles = ScanRegion(x: 0.045, y: 0.28, width: 0.91, height: 0.24)
    static let timer = ScanRegion(x: 0.477, y: 0.741, width: 0.046, height: 0.069)
    static let result = ScanRegion(x: 0.17, y: 0.07, width: 0.66, height: 0.49)

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    func pixels(width: Int, height: Int) -> CGRect {
        CGRect(x: x * Double(width), y: y * Double(height),
               width: self.width * Double(width), height: self.height * Double(height))
            .integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
    }
}

struct Raster {
    var width: Int
    var height: Int
    var gray: [UInt8]
    var white: [UInt8]
    var blue: [UInt8]
    var badge: [UInt8]

    init(width: Int, height: Int, gray: [UInt8], white: [UInt8] = [], blue: [UInt8] = [], badge: [UInt8] = []) {
        self.width = width
        self.height = height
        self.gray = gray
        self.white = white
        self.blue = blue
        self.badge = badge
    }

    init?(buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        self.init(bgra: base.assumingMemoryBound(to: UInt8.self),
                  width: width, height: height, stride: CVPixelBufferGetBytesPerRow(buffer))
    }

    init?(image: CGImage, maxWidth: Int = 1440) {
        let width = min(image.width, maxWidth)
        let height = max(1, image.height * width / image.width)
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
                                      CGBitmapInfo.byteOrder32Little.rawValue),
              let pixels = context.data else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        self.init(bgra: pixels.assumingMemoryBound(to: UInt8.self),
                  width: width, height: height, stride: width * 4)
    }

    private init(bgra: UnsafePointer<UInt8>, width: Int, height: Int, stride: Int) {
        var gray = [UInt8](repeating: 0, count: width * height)
        var white = gray
        var blue = gray
        var badge = gray
        for y in 0..<height {
            let row = bgra + y * stride
            for x in 0..<width {
                let b = Int(row[x * 4]), g = Int(row[x * 4 + 1]), r = Int(row[x * 4 + 2])
                gray[y * width + x] = UInt8((r * 77 + g * 150 + b * 29) >> 8)
                let low = min(r, g, b)
                white[y * width + x] = low >= 224 && max(r, g, b) - low < 23 ? 1 : 0
                blue[y * width + x] = b >= 163 && g >= 112 && b - r >= 24 && b - g >= 12 ? 1 : 0
                if y >= height * 4 / 5 {
                    if (145...245).contains(r) && r - g >= 107 && (6...42).contains(b - g) {
                        badge[y * width + x] = 2
                    } else if (145...235).contains(r) && (65...104).contains(r - g) && abs(b - g) <= 8 {
                        badge[y * width + x] = 1
                    }
                }
            }
        }
        self.init(width: width, height: height, gray: gray, white: white, blue: blue, badge: badge)
    }

    func cropped(to rect: CGRect, includeWhite: Bool = false) -> Raster? {
        let rect = rect.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !rect.isEmpty else { return nil }
        let w = Int(rect.width), h = Int(rect.height)
        let x = Int(rect.minX), y = Int(rect.minY)
        var pixels: [UInt8] = []
        var whitePixels: [UInt8] = []
        pixels.reserveCapacity(w * h)
        if includeWhite { whitePixels.reserveCapacity(w * h) }
        for row in y..<(y + h) {
            let start = row * width + x
            pixels.append(contentsOf: gray[start..<(start + w)])
            if includeWhite {
                whitePixels.append(contentsOf: white[start..<(start + w)])
            }
        }
        return Raster(width: w, height: h, gray: pixels, white: whitePixels)
    }

    func image() -> CGImage? {
        guard let provider = CGDataProvider(data: Data(gray) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

private struct Component {
    let pixels: [Int]
    let bounds: CGRect
}

private func components(_ mask: [UInt8], width: Int, height: Int) -> [Component] {
    var pending = mask
    var result: [Component] = []
    for index in pending.indices where pending[index] == 1 {
        pending[index] = 0
        var queue = [index]
        var head = 0
        var minX = width, maxX = 0, minY = height, maxY = 0
        while head < queue.count {
            let current = queue[head]
            head += 1
            let x = current % width, y = current / width
            minX = min(minX, x)
            maxX = max(maxX, x)
            minY = min(minY, y)
            maxY = max(maxY, y)
            if x > 0, pending[current - 1] == 1 {
                pending[current - 1] = 0
                queue.append(current - 1)
            }
            if x + 1 < width, pending[current + 1] == 1 {
                pending[current + 1] = 0
                queue.append(current + 1)
            }
            if y > 0, pending[current - width] == 1 {
                pending[current - width] = 0
                queue.append(current - width)
            }
            if y + 1 < height, pending[current + width] == 1 {
                pending[current + width] = 0
                queue.append(current + width)
            }
        }
        result.append(Component(pixels: queue, bounds: CGRect(x: minX, y: minY,
                                                               width: maxX - minX + 1, height: maxY - minY + 1)))
    }
    return result
}

private func fillContour(_ contour: Component, width: Int, height: Int) -> [UInt8] {
    var mask = [UInt8](repeating: 1, count: width * height)
    for p in contour.pixels { mask[p] = 0 }
    var queue: [Int] = []
    for y in 0..<height {
        for x in 0..<width where y == 0 || y == height - 1 || x == 0 || x == width - 1 {
            let p = y * width + x
            if mask[p] == 1 {
                mask[p] = 0
                queue.append(p)
            }
        }
    }
    var head = 0
    while head < queue.count {
        let p = queue[head], x = p % width, y = p / width
        head += 1
        if x > 0, mask[p - 1] == 1 {
            mask[p - 1] = 0
            queue.append(p - 1)
        }
        if x + 1 < width, mask[p + 1] == 1 {
            mask[p + 1] = 0
            queue.append(p + 1)
        }
        if y > 0, mask[p - width] == 1 {
            mask[p - width] = 0
            queue.append(p - width)
        }
        if y + 1 < height, mask[p + width] == 1 {
            mask[p + width] = 0
            queue.append(p + width)
        }
    }
    for p in contour.pixels { mask[p] = 1 }
    return mask
}

private struct Shape {
    static let width = 20
    static let height = 24

    let pixels: [UInt8]
    let aspect: Double

    init(mask: [UInt8], width: Int, bounds: CGRect) {
        let dx = bounds.width / Double(Self.width)
        let dy = bounds.height / Double(Self.height)
        var pixels: [UInt8] = []
        pixels.reserveCapacity(Self.width * Self.height)
        for y in 0..<Self.height {
            for x in 0..<Self.width {
                let sx = Int(bounds.minX + (Double(x) + 0.5) * dx)
                let sy = Int(bounds.minY + (Double(y) + 0.5) * dy)
                pixels.append(mask[sy * width + sx])
            }
        }
        self.pixels = pixels
        aspect = bounds.width / bounds.height
    }

    func distance(to other: Shape) -> Double {
        var mismatch = 0
        for i in pixels.indices where pixels[i] != other.pixels[i] { mismatch += 1 }
        let aspectDistance = min(0.5, abs(log(aspect / other.aspect))) * 0.23
        return Double(mismatch) / Double(pixels.count) + aspectDistance
    }
}

private struct TileGlyph {
    let shape: Shape
    let raw: Raster

    init?(crop: Raster) {
        let mask = crop.gray.map { $0 < 154 ? UInt8(1) : UInt8(0) }
        let dark = components(mask, width: crop.width, height: crop.height)
            .filter { $0.pixels.count >= 3 }
            .sorted { $0.pixels.count > $1.pixels.count }
        guard let outline = dark.first,
              outline.bounds.height > Double(crop.height) * 0.37,
              outline.bounds.width > Double(crop.width) * 0.105,
              outline.bounds.minX >= 0, outline.bounds.maxX <= Double(crop.width),
              outline.bounds.minY >= 0, outline.bounds.maxY <= Double(crop.height) else { return nil }

        var filled = fillContour(outline, width: crop.width, height: crop.height)
        for inner in dark.dropFirst() where outline.bounds.insetBy(dx: 1, dy: 1).contains(inner.bounds) {
            let interior = fillContour(inner, width: crop.width, height: crop.height)
            let outlinePixels = Set(inner.pixels)
            for p in interior.indices where interior[p] == 1 && !outlinePixels.contains(p) {
                filled[p] = 0
            }
        }
        shape = Shape(mask: filled, width: crop.width, bounds: outline.bounds)
        raw = Raster(width: crop.width, height: crop.height, gray: filled.map { $0 == 1 ? 0 : 255 })
    }
}

private struct RecognizedText {
    let value: String
    let bounds: CGRect
    let confidence: Float
}

final class TileReader {
    private let templates: [(Character, Shape)]
    private var cachedShapes: [[UInt8]] = []
    private var cachedPrefix: String?
    private var lastTimer = -Double.infinity
    private var lastResult = -Double.infinity
    private var recentResult: String?
    private var lastPlayedSample = -Double.infinity
    private var playedRegion: ScanRegion?
    private var playedCandidate: String?
    private var lastEmittedWord: String?
    private var lastGoodClock = -Double.infinity

    init(fontURL: URL? = Bundle.main.url(forResource: "Fredoka", withExtension: "ttf")) {
        let names = ["ArialRoundedMTBold", "AvenirNext-Heavy", "HelveticaNeue-Bold",
                     "TrebuchetMS-Bold", "GillSans-Bold", "Arial-Black", "Verdana-Bold",
                     "AvenirNext-DemiBold"]
        var fonts = names.map { CTFontCreateWithName($0 as CFString, 64, nil) }
        if let fontURL,
           let descriptors = CTFontManagerCreateFontDescriptorsFromURL(fontURL as CFURL) as? [CTFontDescriptor],
           let descriptor = descriptors.first {
            let weightAxis = NSNumber(value: 0x77676874) // OpenType wght
            let base = CTFontCreateWithFontDescriptor(descriptor, 64, nil)
            for weight in [500, 700] {
                let adjusted = CTFontDescriptorCreateCopyWithVariation(
                    CTFontCopyFontDescriptor(base), weightAxis, CGFloat(weight)
                )
                fonts.append(CTFontCreateWithFontDescriptor(adjusted, 64, nil))
            }
        }
        templates = fonts.flatMap { font in
            "ABCDEFGHIJKLMNOPQRSTUVWXYZ".compactMap { letter in
                Self.template(letter: letter, font: font).map { (letter, $0) }
            }
        }
    }

    func read(_ raster: Raster, region: ScanRegion, now: TimeInterval, inspectClock: Bool = true,
              inspectResults: Bool = true, playedRegion: ScanRegion? = nil, robloxHUD: Bool = false) -> Reading {
        let tiles = findTiles(in: raster, region: region)
        var stableShapes = false
        let glyphs = tiles.compactMap { rect -> TileGlyph? in
            guard let crop = raster.cropped(to: rect.insetBy(dx: rect.width * 0.085, dy: rect.height * 0.085))
            else { return nil }
            return TileGlyph(crop: crop)
        }
        var prefix: String?
        if !tiles.isEmpty, tiles.count == glyphs.count {
            let shapes = glyphs.map(\.shape.pixels)
            if shapes == cachedShapes {
                stableShapes = true
                prefix = cachedPrefix
            } else {
                recentResult = nil
                prefix = recognize(glyphs)
                cachedShapes = shapes
                cachedPrefix = prefix
            }
        }

        let clockVisible = robloxHUD ? hasClockFace(in: raster) : nil
        var seconds: Double?
        let clockWasReadable = robloxHUD && now - lastGoodClock < 1.6
        if inspectClock, (clockVisible == true || prefix != nil || clockWasReadable), now - lastTimer >= 0.27 {
            lastTimer = now
            seconds = clock(in: raster)
            if seconds != nil { lastGoodClock = now }
        }

        let mayShowResult = clockVisible == false || prefix == nil || (stableShapes && now - lastGoodClock >= 1.4)
        if inspectResults, mayShowResult, now - lastResult >= 0.85 {
            lastResult = now
            recentResult = finishBanner(in: raster)
        } else if !mayShowResult {
            recentResult = nil
        }
        let playedWord = playedWord(in: raster, region: playedRegion, now: now)
        return Reading(prefix: prefix, tilesPresent: !tiles.isEmpty, seconds: seconds, result: recentResult,
                       playedWord: playedWord, clockVisible: clockVisible,
                       mistakes: robloxHUD && clockVisible == true ? mistakeBadges(in: raster) : nil)
    }

    private func hasClockFace(in raster: Raster) -> Bool {
        guard !raster.blue.isEmpty else { return false }
        let centerX = Double(raster.width) * 0.50
        let scale = Double(raster.height)
        for y in [0.739, 0.758, 0.769, 0.783, 0.798] {
            let centerY = scale * y
            for radius in [0.047, 0.052, 0.057].map({ scale * $0 }) {
                let inner = [(-0.55, 0.0), (0.55, 0.0), (0.0, -0.49), (0.0, 0.52)]
                func point(_ dx: Double, _ dy: Double, _ radius: Double) -> Int? {
                    let x = Int((centerX + radius * dx).rounded())
                    let y = Int((centerY + radius * dy).rounded())
                    guard (0..<raster.width).contains(x), (0..<raster.height).contains(y) else { return nil }
                    return y * raster.width + x
                }
                let face = inner.compactMap { point($0.0, $0.1, radius) }.filter { raster.white[$0] == 1 }
                guard face.count >= 3 else { continue }
                let ring = (0..<12).filter { index in
                    let angle = Double(index) * .pi / 6
                    return [0.85, 0.93, 1.01].contains { stretch in
                        point(cos(angle), sin(angle), radius * stretch).map { raster.blue[$0] == 1 } == true
                    }
                }
                if ring.count >= 7 { return true }
            }
        }
        return false
    }

    private func playedWord(in raster: Raster, region: ScanRegion?, now: TimeInterval) -> String? {
        if playedRegion != region {
            playedRegion = region
            playedCandidate = nil
            lastEmittedWord = nil
            lastPlayedSample = -Double.infinity
        }
        guard let region, now - lastPlayedSample >= 0.12 else { return nil }
        lastPlayedSample = now
        guard let crop = raster.cropped(to: region.pixels(width: raster.width, height: raster.height)),
              let image = crop.image() else { return nil }
        let scale = crop.height < 100 ? 2 : 1
        guard let enlarged = scale == 1 ? image : Self.enlarge(image, by: scale) else { return nil }
        let text = Self.text(in: enlarged, fast: false)
        let word = text.count == 1 && text[0].confidence >= 0.52 ? WordOptions.normalize(text[0].value) : nil
        guard let word else {
            playedCandidate = nil
            lastEmittedWord = nil
            return nil
        }
        let previous = playedCandidate
        playedCandidate = word
        guard previous == word, lastEmittedWord != word else { return nil }
        lastEmittedWord = word
        return word
    }

    private func findTiles(in raster: Raster, region: ScanRegion) -> [CGRect] {
        let zone = region.pixels(width: raster.width, height: raster.height)
        guard let crop = raster.cropped(to: zone, includeWhite: true) else { return [] }
        let target = Double(raster.height) * 0.083
        let candidates = components(crop.white, width: crop.width, height: crop.height)
            .compactMap { part -> CGRect? in
                let bounds = part.bounds
                let fill = Double(part.pixels.count) / (bounds.width * bounds.height)
                guard bounds.height > max(17, target * 0.45), bounds.height < target * 1.72,
                      bounds.width / bounds.height > 0.77, bounds.width / bounds.height < 1.23,
                      bounds.minX > 0, bounds.minY > 0, bounds.maxX < Double(crop.width),
                      bounds.maxY < Double(crop.height), fill > 0.52, fill < 0.988 else { return nil }
                let rect = bounds.offsetBy(dx: zone.minX, dy: zone.minY)
                let inset = max(2, Int(rect.width * 0.075))
                let x = Int(rect.minX), y = Int(rect.minY), w = Int(rect.width), h = Int(rect.height)
                let sides = [(x + w / 3, y, 0, -1), (x + w * 2 / 3, y, 0, -1),
                             (x + w / 3, y + h - 1, 0, 1), (x + w * 2 / 3, y + h - 1, 0, 1),
                             (x, y + h / 2, -1, 0), (x + w - 1, y + h / 2, 1, 0)]
                let darkEdges = sides.filter { point in
                    (1...inset).contains { step in
                        let px = point.0 + point.2 * step
                        let py = point.1 + point.3 * step
                        return (0..<raster.width).contains(px) && (0..<raster.height).contains(py)
                            && raster.gray[py * raster.width + px] < 96
                    }
                }.count
                return darkEdges >= 3 ? rect : nil
            }.sorted { $0.minX < $1.minX }

        var rows: [[CGRect]] = []
        for start in candidates.indices {
            var row = [candidates[start]]
            for next in candidates.dropFirst(start + 1) {
                guard let last = row.last else { break }
                let gap = next.minX - last.maxX
                if gap > last.width * 0.46 { break }
                if gap >= last.width * 0.022, abs(next.midY - last.midY) < last.height * 0.36,
                   abs(next.height - last.height) < last.height * 0.21 {
                    row.append(next)
                }
            }
            rows.append(row)
        }
        let cx = zone.midX
        let cy = zone.midY
        let centered = rows.filter { row in
            guard let first = row.first, let last = row.last else { return false }
            let center = (first.minX + last.maxX) / 2
            return abs(center - cx) <= first.width * 0.47
        }
        func score(_ row: [CGRect]) -> Double {
            let area = row.dropFirst().reduce(row[0]) { $0.union($1) }
            return Double(row.count - 1) * 0.45 - abs(area.midX - cx) / zone.width * 4.5
                - abs(area.midY - cy) / zone.height * 1.5
                - abs(log(row[0].height / target)) * 0.65
        }
        return centered.max { score($0) < score($1) } ?? []
    }

    private func mistakeBadges(in raster: Raster) -> Int? {
        guard !raster.badge.isEmpty else { return nil }
        let scale = Double(raster.height)
        let center = Double(raster.width) / 2
        var result: Int?
        var best = 0
        for row in 0..<19 {
            let y = (0.854 + Double(row) * 0.0045) * scale
            for spacing in [0.101, 0.106, 0.111, 0.116, 0.121] {
                var marks = 0
                var strength = 0
                var foundInactive = false
                for column in -2...2 {
                    let centerX = center + Double(column) * spacing * scale
                    var muted = 0
                    var active = 0
                    for dy in [-0.015, 0.0, 0.015] {
                        for dx in [-0.021, -0.010, 0.010, 0.021] {
                            let x = Int(centerX + dx * scale)
                            let yy = Int(y + dy * scale)
                            guard (0..<raster.width).contains(x), (0..<raster.height).contains(yy) else { continue }
                            let badge = raster.badge[yy * raster.width + x]
                            if badge == 1 { muted += 1 }
                            if badge == 2 { active += 1 }
                        }
                    }
                    if active >= 6 && !foundInactive { marks += 1; strength += active }
                    else if muted >= 7 { foundInactive = true; strength += muted }
                    else { strength = 0; break }
                }
                if strength > best { best = strength; result = marks }
            }
        }
        return result
    }

    private func recognize(_ glyphs: [TileGlyph]) -> String? {
        let ranks: [[(Character, Double)]] = glyphs.map { glyph in
            var best: [Character: Double] = [:]
            for (char, template) in templates {
                let distance = glyph.shape.distance(to: template)
                best[char] = min(best[char] ?? 1.0, distance)
            }
            return best.sorted { $0.value < $1.value }.prefix(4).map { ($0.key, $0.value) }
        }
        let alternatives = ranks.compactMap(\.first)
        guard alternatives.count == glyphs.count else { return nil }
        if ranks.allSatisfy({ $0[0].1 <= 0.30 && $0[1].1 - $0[0].1 > 0.022 }) {
            return String(alternatives.map(\.0))
        }
        if let vision = recognizeRow(glyphs), vision.count == glyphs.count,
           zip(vision, ranks).allSatisfy({ char, options in
               options.contains { $0.0 == char && $0.1 <= min(0.47, options[0].1 + 0.075) }
           }) {
            return vision
        }
        guard alternatives.allSatisfy({ $0.1 < 0.32 }) else { return nil }
        return String(alternatives.map(\.0))
    }

    private func recognizeRow(_ glyphs: [TileGlyph]) -> String? {
        let glyphHeight = 86, spacing = 9, margin = 18
        let copies = glyphs.count == 1 ? glyphs + glyphs : glyphs
        let widths = copies.map { Int(Double(glyphHeight) * Double($0.raw.width) / Double($0.raw.height)) }
        let width = widths.reduce(0, +) + spacing * (copies.count - 1) + margin * 2
        let height = glyphHeight + margin * 2
        var pixels = [UInt8](repeating: 255, count: width * height)
        var offset = margin
        for (glyph, w) in zip(copies, widths) {
            let shape = glyph.raw
            for y in 0..<glyphHeight {
                for x in 0..<w {
                    pixels[(y + margin) * width + offset + x] =
                        shape.gray[(y * shape.height / glyphHeight) * shape.width + x * shape.width / w]
                }
            }
            offset += w + spacing
        }
        guard let image = Raster(width: width, height: height, gray: pixels).image() else { return nil }
        let text = Self.text(in: image, fast: false).map(\.value).joined().uppercased()
        let letters = text.filter { $0.isASCII && $0.isLetter }
        if glyphs.count == 1, letters.count == 2, letters.first == letters.last { return String(letters.prefix(1)) }
        return letters
    }

    private func clock(in raster: Raster) -> Double? {
        let region = ScanRegion.timer.pixels(width: raster.width, height: raster.height)
        guard let crop = raster.cropped(to: region),
              let image = crop.image(), let enlarged = Self.enlarge(image, by: 3) else { return nil }
        let rawText = Self.text(in: enlarged, fast: false)
        if let value = Self.clockValue(rawText) { return value }
        guard !rawText.isEmpty else { return nil }
        let highContrast = Raster(width: crop.width, height: crop.height,
                                  gray: crop.gray.map { $0 < 62 ? 0 : 255 })
        if let image = highContrast.image(), let enlarged = Self.enlarge(image, by: 4),
           let value = Self.clockValue(Self.text(in: enlarged, fast: false)) {
            return value
        }
        // The decimal dot can join the first digit at capture resolution. Its low,
        // narrow segment remains visible below the gap between the numeral bodies.
        guard let item = rawText.first, item.confidence >= 0.55,
              (2...3).contains(item.value.count),
              item.value.allSatisfy({ $0.isASCII && $0.isNumber }),
              Self.hasClockDot(crop, text: item),
              let number = Double(item.value), number <= 900 else { return nil }
        return number / 10
    }

    private static func clockValue(_ items: [RecognizedText]) -> Double? {
        for item in items where item.confidence >= 0.35 {
            let text = item.value.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: ",", with: ".")
            if let number = Double(text), (0...90).contains(number), text.contains(".") || text.count == 1 {
                return number
            }
        }
        return nil
    }

    private static func hasClockDot(_ raster: Raster, text: RecognizedText) -> Bool {
        let box = text.bounds
        let digitCount = text.value.count
        let pivot = digitCount == 2 ? 0.50 : 0.66
        let center = Int((box.minX + box.width * pivot) * Double(raster.width))
        let spread = max(2, Int(box.width * Double(raster.width) * 0.09))
        let top = max(0, Int((1 - box.maxY) * Double(raster.height)))
        let bottom = min(raster.height, Int((1 - box.minY) * Double(raster.height)) + 1)
        let division = top + Int(Double(bottom - top) * 0.65)
        guard bottom - top >= 9, center >= spread, center + spread < raster.width else { return false }
        let dotColumns = ((center - spread)...(center + spread)).filter { x in
            let head = (top..<division).filter { raster.gray[$0 * raster.width + x] < 73 }.count
            let foot = (division..<bottom).filter { raster.gray[$0 * raster.width + x] < 73 }.count
            return head <= 1 && foot >= 2
        }
        return dotColumns.count >= 2
    }

    private func finishBanner(in raster: Raster) -> String? {
        let region = ScanRegion.result.pixels(width: raster.width, height: raster.height)
        guard let image = raster.cropped(to: region)?.image() else { return nil }
        let phrases = ["game over", "match over", "round over", "match ended", "game ended",
                       "you win", "you won", "you lose", "you lost", "victory", "defeat",
                       "winner is"]
        for item in Self.text(in: image, fast: false) where item.confidence >= 0.36 && item.bounds.height >= 0.043 {
            let clean = item.value.lowercased().map { $0.isLetter || $0.isWhitespace ? $0 : " " }
            let line = String(clean).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if phrases.contains(where: { line == $0 || line.hasPrefix($0 + " ") }) {
                return item.value
            }
        }
        return nil
    }

    private static func text(in image: CGImage, fast: Bool) -> [RecognizedText] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = fast ? .fast : .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.023
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            return []
        }
        return (request.results ?? []).sorted { $0.boundingBox.minX < $1.boundingBox.minX }.compactMap {
            guard let text = $0.topCandidates(1).first else { return nil }
            return RecognizedText(value: text.string, bounds: $0.boundingBox, confidence: text.confidence)
        }
    }

    private static func enlarge(_ image: CGImage, by scale: Int) -> CGImage? {
        let w = image.width * scale, h = image.height * scale
        let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)
        context?.interpolationQuality = .high
        context?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context?.makeImage()
    }

    private static func template(letter: Character, font: CTFont) -> Shape? {
        let w = 88, h = 88
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0),
              let data = context.data else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let attributed = NSAttributedString(string: String(letter), attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                CGColor(gray: 0, alpha: 1)
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: 10, y: 17)
        CTLineDraw(line, context)
        let buffer = UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: w * h)
        let mask = buffer.map { $0 < 155 ? UInt8(1) : UInt8(0) }
        let xs = mask.indices.filter { mask[$0] == 1 }
        guard let l = xs.map({ $0 % w }).min(), let r = xs.map({ $0 % w }).max(),
              let top = xs.first.map({ $0 / w }), let bottom = xs.last.map({ $0 / w }) else { return nil }
        return Shape(mask: mask, width: w, bounds: CGRect(x: l, y: top, width: r - l + 1, height: bottom - top + 1))
    }
}
