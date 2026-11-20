import AppKit
import SwiftUI
import ScreenCaptureKit
import ImageIO

struct Preferences: Codable, Equatable {
    var turnSeconds = 10
    var endSeconds = 30
    var minimumLength = 3
    var floating = true
    var region = ScanRegion.tiles
    var suggestionCount: Int?
    var customWords: [String]?
    var customLimit: Int?
    var trackSubmissions: Bool?
    var playedRegion: ScanRegion?

    var wordOptions: WordOptions {
        WordOptions(minimumLength: minimumLength, count: min(100, max(1, suggestionCount ?? 5)),
                    custom: Array((customWords ?? []).prefix(100)), customLimit: min(100, max(0, customLimit ?? 100)))
    }

    var tracksKeyboard: Bool { trackSubmissions ?? true }
}

enum WatchState: Equatable {
    case stopped, starting, watching, failed
}

@MainActor
final class Dashboard: ObservableObject {
    @Published private(set) var watch = WatchState.stopped
    @Published private(set) var match = Match()
    @Published private(set) var windows: [WindowChoice] = []
    @Published private(set) var sourceName = "Roblox"
    @Published private(set) var message: String?
    @Published private(set) var copied: String?
    @Published private(set) var preview: CGImage?
    @Published private(set) var previewMessage: String?
    @Published private(set) var previewBusy = false
    @Published private(set) var hotkeysAvailable = true
    @Published private(set) var keyboardStatus: KeyboardStatus = .inactive
    @Published var sourceID: CGWindowID?
    @Published var preferences: Preferences {
        didSet {
            if let data = try? JSONEncoder().encode(preferences) {
                UserDefaults.standard.set(data, forKey: "wordRelayPreferences")
            }
            if oldValue.region != preferences.region || oldValue.playedRegion != preferences.playedRegion {
                sink?.setRegions(tiles: preferences.region, played: preferences.playedRegion)
                if oldValue.region != preferences.region {
                    engine.resume()
                    submissionListener?.clearDraft()
                }
            }
            if oldValue.suggestionCount != preferences.suggestionCount || oldValue.customWords != preferences.customWords ||
                oldValue.customLimit != preferences.customLimit || oldValue.minimumLength != preferences.minimumLength {
                engine.restartSuggestions(lexicon: lexicon, options: preferences.wordOptions)
                publishMatch()
            }
            if oldValue.tracksKeyboard != preferences.tracksKeyboard {
                configureSubmissionListener()
            }
            if oldValue.floating != preferences.floating {
                setFloating?(preferences.floating)
            }
        }
    }

    let lexicon: Lexicon
    var setFloating: ((Bool) -> Void)?
    private var engine = Match()
    private var stream: SCStream?
    private var sink: CaptureSink?
    private var generation = UUID()
    private var copyGeneration = UUID()
    private var lastCaptureAt: TimeInterval?
    private var lastReading: Reading?
    private var windowHealthCheck: Timer?
    private var submissionListener: SubmissionListener?
    private var submissionPid: pid_t?
    private var focusObserver: NSObjectProtocol?
    private var ownedClipboard: (word: String, change: Int)?

    enum KeyboardStatus: Equatable {
        case inactive, needsPermission, listening, unavailable
    }

    init() {
        let data = UserDefaults.standard.data(forKey: "wordRelayPreferences")
        var saved = data.flatMap { try? JSONDecoder().decode(Preferences.self, from: $0) } ?? Preferences()
        if saved.region == .previousTiles { saved.region = .tiles }
        preferences = saved
        func words(named name: String) -> String {
            Bundle.main.url(forResource: name, withExtension: "txt")
                .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        }
        lexicon = Lexicon(contents: words(named: "words"), extended: words(named: "words-extra"))
    }

    func disableHotkeyIndicator() { hotkeysAvailable = false }

    func start() {
        guard watch != .starting, watch != .watching else { return }
        watch = .starting
        message = nil
        let token = UUID()
        generation = token
        engine.resume()
        Task { await connect(token: token) }
    }

    func stop() {
        generation = UUID()
        let previous = stream
        stream = nil
        sink = nil
        submissionPid = nil
        stopSubmissionListener()
        keyboardStatus = .inactive
        lastCaptureAt = nil
        lastReading = nil
        windowHealthCheck?.invalidate()
        windowHealthCheck = nil
        watch = .stopped
        message = nil
        if let previous {
            Task { try? await previous.stopCapture() }
        }
    }

    func newMatch() {
        engine = Match()
        submissionListener?.clearDraft()
        lastReading = nil
        publishMatch()
    }

    func lookup(_ letters: String) {
        let prefix = letters.lowercased().filter { $0.isASCII && $0.isLetter }.prefix(WordOptions.maximumWordLength)
        guard !prefix.isEmpty else { return }
        if engine.phase == .finished { engine = Match() }
        engine.startTurn(String(prefix), now: Self.now, seconds: nil, lexicon: lexicon,
                         options: preferences.wordOptions)
        publishMatch()
    }

    func nextWords() {
        engine.nextWords(lexicon: lexicon, options: preferences.wordOptions)
        publishMatch()
    }

    func copy(_ word: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(word, forType: .string)
        ownedClipboard = (word, NSPasteboard.general.changeCount)
        copied = word
        let token = UUID()
        copyGeneration = token
        Task {
            try? await Task.sleep(nanoseconds: 1_150_000_000)
            if copyGeneration == token { copied = nil }
        }
    }

    func recordPlayed(_ raw: String) {
        guard let word = WordOptions.normalize(raw) else { return }
        engine.record(word, source: .manual, lexicon: lexicon, options: preferences.wordOptions)
        publishMatch()
    }

    func removePlayed(_ word: String) {
        engine.removePlayed(word, lexicon: lexicon, options: preferences.wordOptions)
        publishMatch()
    }

    func allowInputMonitoring() {
        if CGPreflightListenEventAccess() || CGRequestListenEventAccess() {
            configureSubmissionListener()
        } else if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        ) {
            NSWorkspace.shared.open(url)
        }
    }

    func refreshWindows() {
        guard CGPreflightScreenCaptureAccess() else { return }
        Task {
            if let windows = try? await CaptureSource.windows() {
                self.windows = CaptureSource.choices(windows)
            }
        }
    }

    func selectWindow(_ id: CGWindowID?) {
        guard sourceID != id else { return }
        sourceID = id
        preview = nil
        previewMessage = nil
        if watch == .starting || watch == .watching {
            stop()
            start()
        }
    }

    func capturePreview() {
        guard !previewBusy else { return }
        let choice = sourceID
        previewBusy = true
        previewMessage = nil
        Task {
            defer { previewBusy = false }
            do {
                try requirePermission()
                let available = try await CaptureSource.windows()
                windows = CaptureSource.choices(available)
                let window = try CaptureSource.resolve(choice, windows: available)
                let filter = CaptureSource.filter(window)
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: CaptureSource.config(filter)
                )
                guard sourceID == choice else { return }
                preview = image
            } catch {
                previewMessage = error.localizedDescription
            }
        }
    }

    func loadImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.prompt = "Read Image"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await self.readImage(url) }
        }
    }

    private func readImage(_ url: URL) async {
        let region = preferences.region
        let reading = await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let raster = Raster(image: image) else { return nil as Reading? }
            return TileReader().read(raster, region: region, now: Self.now, inspectResults: false)
        }.value
        guard watch != .starting, watch != .watching else { return }
        if let reading, let prefix = reading.prefix {
            if engine.phase == .finished { engine = Match() }
            engine.startTurn(prefix, now: Self.now, seconds: reading.seconds, lexicon: lexicon,
                             options: preferences.wordOptions)
            message = nil
            publishMatch()
        } else {
            message = "No clear letter tiles found in that image."
        }
    }

    func openScreenSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    nonisolated static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func connect(token: UUID) async {
        do {
            try requirePermission()
            let available = try await CaptureSource.windows()
            guard generation == token else { return }
            windows = CaptureSource.choices(available)
            let window = try CaptureSource.resolve(sourceID, windows: available)
            sourceName = window.owningApplication?.applicationName ?? "Selected window"
            let filter = CaptureSource.filter(window)
            let sink = CaptureSink(region: preferences.region, playedRegion: preferences.playedRegion,
                                   robloxHUD: CaptureSource.isRoblox(window)) {
                [weak self] reading, now in
                DispatchQueue.main.async { self?.receive(reading, now: now, token: token) }
            } failure: { [weak self] error in
                DispatchQueue.main.async { self?.failed(error, token: token) }
            }
            let stream = SCStream(filter: filter, configuration: CaptureSource.config(filter), delegate: sink)
            try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
            guard generation == token else { return }
            self.sink = sink
            self.stream = stream
            try await stream.startCapture()
            guard generation == token else {
                try? await stream.stopCapture()
                return
            }
            watch = .watching
            submissionPid = CaptureSource.isRoblox(window) ? window.owningApplication?.processID : nil
            configureSubmissionListener()
            let startedAt = Self.now
            windowHealthCheck = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.checkCapture(startedAt: startedAt, token: token)
                }
            }
        } catch {
            failed(error, token: token)
        }
    }

    private func requirePermission() throws {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw CaptureIssue.permission
        }
    }

    private func checkCapture(startedAt: TimeInterval, token: UUID) {
        guard generation == token else { return }
        let now = Self.now
        if now - (lastCaptureAt ?? startedAt) >= 3 {
            message = "Waiting for a visible \(sourceName) window."
        }
        // ScreenCaptureKit may stop sending frames when a scene becomes completely still.
        if var reading = lastReading, !reading.tilesPresent {
            reading.playedWord = nil
            receive(reading, now: now, token: token, actualFrame: false)
        }
    }

    private func receive(_ reading: Reading, now: TimeInterval, token: UUID, actualFrame: Bool = true) {
        guard generation == token else { return }
        if actualFrame {
            lastCaptureAt = now
            lastReading = reading
            message = nil
        }
        let turn = engine.turns
        let phase = engine.phase
        if let word = reading.playedWord, phase == .turn || phase == .between {
            acceptTrackedWord(word, source: .onScreen)
        }
        engine.ingest(reading, now: now, endAfter: Double(preferences.endSeconds), lexicon: lexicon,
                      options: preferences.wordOptions)
        if engine.turns != turn || phase != engine.phase && engine.phase != .turn {
            submissionListener?.clearDraft()
        }
        publishMatch()
    }

    private func configureSubmissionListener() {
        stopSubmissionListener()
        guard watch == .watching, let pid = submissionPid, preferences.tracksKeyboard else {
            keyboardStatus = .inactive
            return
        }
        guard CGPreflightListenEventAccess() else {
            keyboardStatus = .needsPermission
            return
        }
        let listener = SubmissionListener(pid: pid, canRead: { [weak self] in
            guard let self, self.watch == .watching,
                  let frameAt = self.lastCaptureAt, Self.now - frameAt < 0.6,
                  self.lastReading?.prefix != nil || self.engine.hasLiveClock(at: Self.now) else { return false }
            return self.engine.phase == .turn || self.engine.phase == .between
        }, pastedSuggestion: { [weak self] in
            guard let clipboard = self?.ownedClipboard,
                  clipboard.change == NSPasteboard.general.changeCount else { return nil }
            return clipboard.word
        }) { [weak self] word in
            self?.acceptTrackedWord(word, source: .submitted)
        }
        guard listener.start() else {
            keyboardStatus = .unavailable
            return
        }
        submissionListener = listener
        keyboardStatus = .listening
        focusObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.submissionListener?.clearDraft() }
        }
    }

    private func stopSubmissionListener() {
        submissionListener?.stop()
        submissionListener = nil
        if let focusObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(focusObserver)
            self.focusObserver = nil
        }
    }

    private func acceptTrackedWord(_ word: String, source: PlayedSource) {
        let displayed = lastReading?.prefix?.lowercased() ?? ""
        let prefixes = [engine.prefix, engine.previousPrefix, displayed]
        guard prefixes.contains(where: { !$0.isEmpty && word.hasPrefix($0) }),
              lexicon.contains(word) || preferences.wordOptions.custom.contains(word) else { return }
        engine.record(word, source: source, lexicon: lexicon, options: preferences.wordOptions)
        publishMatch()
    }

    private func failed(_ error: Error, token: UUID) {
        guard generation == token else { return }
        stop()
        watch = .failed
        message = error.localizedDescription
    }

    private func publishMatch() {
        if match.phase != engine.phase || match.prefix != engine.prefix || match.history.count != engine.history.count ||
            match.suggestions != engine.suggestions || match.canCycleSuggestions != engine.canCycleSuggestions ||
            match.turns != engine.turns || match.played != engine.played ||
            match.clockObservedAt != engine.clockObservedAt || match.finishReason != engine.finishReason {
            match = engine
        }
    }
}
