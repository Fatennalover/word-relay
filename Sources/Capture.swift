import AppKit
import CoreMedia
import ScreenCaptureKit
import CoreImage

struct WindowChoice: Identifiable {
    let id: CGWindowID
    let name: String
    let game: Bool
}

enum CaptureIssue: LocalizedError {
    case permission, windowMissing, invalidFrame

    var errorDescription: String? {
        switch self {
        case .permission:
            return "Allow Word Relay under Screen & System Audio Recording in System Settings, then reopen it."
        case .windowMissing:
            return "Open a Roblox game window or choose another window in Settings."
        case .invalidFrame:
            return "The selected window did not return a usable image."
        }
    }
}

enum CaptureSource {
    static func windows() async throws -> [SCWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        return content.windows.filter {
            $0.frame.width >= 320 && $0.frame.height >= 180 && $0.windowLayer == 0 &&
                $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier
        }
    }

    static func choices(_ windows: [SCWindow]) -> [WindowChoice] {
        windows.compactMap { window in
            guard let application = window.owningApplication else { return nil }
            let title = window.title ?? ""
            let name = title.isEmpty || title == application.applicationName ? application.applicationName :
                "\(application.applicationName) · \(title)"
            return WindowChoice(id: window.windowID, name: name, game: isRoblox(window))
        }.sorted {
            if $0.game != $1.game { return $0.game }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func resolve(_ choice: CGWindowID?, windows: [SCWindow]) throws -> SCWindow {
        let match = choice.flatMap { id in windows.first { $0.windowID == id } }
        if let match { return match }
        guard choice == nil,
              let roblox = windows.filter({ isRoblox($0) }).max(by: { area($0.frame) < area($1.frame) })
        else { throw CaptureIssue.windowMissing }
        return roblox
    }

    static func filter(_ window: SCWindow) -> SCContentFilter {
        SCContentFilter(desktopIndependentWindow: window)
    }

    static func config(_ filter: SCContentFilter) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let rect = filter.contentRect
        config.width = 1440
        config.height = min(1760, max(340, Int(1440 * rect.height / max(rect.width, 1))))
        config.minimumFrameInterval = CMTime(value: 1, timescale: 10)
        config.queueDepth = 3
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.capturesAudio = false
        config.ignoreShadowsSingleWindow = true
        config.scalesToFit = true
        config.preservesAspectRatio = true
        return config
    }

    static func isRoblox(_ window: SCWindow) -> Bool {
        let id = window.owningApplication?.bundleIdentifier.lowercased() ?? ""
        return id == "com.roblox.robloxplayer" || id == "com.roblox.roblox"
    }

    private static func area(_ rect: CGRect) -> CGFloat { rect.width * rect.height }
}

final class CaptureSink: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "WordRelay.capture", qos: .userInitiated)
    private let reader = TileReader()
    private var region: ScanRegion
    private var playedRegion: ScanRegion?
    private let robloxHUD: Bool
    private var lastReading: Reading?
    private var lastFrame = -Double.infinity
    private let update: (Reading, TimeInterval) -> Void
    private let failure: (Error) -> Void
    private let processingContext = CIContext(options: [.cacheIntermediates: false])

    init(region: ScanRegion, playedRegion: ScanRegion? = nil, robloxHUD: Bool = false, update: @escaping (Reading, TimeInterval) -> Void,
         failure: @escaping (Error) -> Void) {
        self.region = region
        self.playedRegion = playedRegion
        self.robloxHUD = robloxHUD
        self.update = update
        self.failure = failure
    }

    func setRegions(tiles: ScanRegion, played: ScanRegion?) {
        queue.async {
            self.region = tiles
            self.playedRegion = played
            self.lastReading = nil
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let array = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let info = array.first,
              let raw = info[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if status == .idle, now - lastFrame >= 0.18, var lastReading {
            lastReading.seconds = nil
            lastReading.playedWord = nil
            lastFrame = now
            update(lastReading, now)
            return
        }
        guard status == .complete, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              now - lastFrame >= 0.075 else { return }
        let frame = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        let raster: Raster?
        if let value = info[.contentRect] as? NSDictionary,
           let bounds = CGRect(dictionaryRepresentation: value as CFDictionary),
           bounds.width > 100, bounds.height > 100 {
            let scale = (info[.scaleFactor] as? NSNumber)?.doubleValue ?? 1
            let rect = CGRect(x: bounds.minX * scale, y: bounds.minY * scale,
                              width: bounds.width * scale, height: bounds.height * scale)
                .integral.intersection(frame)
            if rect.width > frame.width * 0.40, rect.height > frame.height * 0.40,
               rect.width < frame.width - 8 || rect.height < frame.height - 8 {
                let image = CIImage(cvPixelBuffer: buffer)
                let fromBottom = CGRect(x: rect.minX, y: frame.height - rect.maxY,
                                        width: rect.width, height: rect.height)
                raster = processingContext.createCGImage(image, from: fromBottom).flatMap { Raster(image: $0) }
            } else {
                raster = Raster(buffer: buffer)
            }
        } else {
            raster = Raster(buffer: buffer)
        }
        guard let raster else { return }
        let reading = reader.read(raster, region: region, now: now, playedRegion: playedRegion, robloxHUD: robloxHUD)
        lastReading = reading
        lastFrame = now
        update(reading, now)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { failure(error) }
}
