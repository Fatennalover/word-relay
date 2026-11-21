import SwiftUI

private let canvasColor = Color(red: 0.065, green: 0.102, blue: 0.116)
private let surface = Color(red: 0.095, green: 0.150, blue: 0.166)
private let edge = Color(red: 0.16, green: 0.25, blue: 0.26)
private let mint = Color(red: 0.69, green: 0.98, blue: 0.84)
private let ink = Color(red: 0.044, green: 0.145, blue: 0.120)
private let bright = Color(red: 0.91, green: 0.96, blue: 0.95)
private let dim = Color(red: 0.63, green: 0.73, blue: 0.73)
private let amber = Color(red: 1.0, green: 0.76, blue: 0.49)

struct DashboardView: View {
    @ObservedObject var model: Dashboard
    @State private var entry = ""
    @State private var batch = 0
    @State private var sheet: Shelf?

    private enum Shelf: String, Identifiable {
        case settings, history
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            header
            prompt
            controls
            words
            manual
            footer
        }
        .padding(22)
        .frame(width: 386, height: 646)
        .foregroundStyle(bright)
        .background(canvasColor)
        .preferredColorScheme(.dark)
        .sheet(item: $sheet) { item in
            switch item {
            case .settings: SettingsView(model: model)
            case .history: HistoryView(model: model)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "text.viewfinder")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(mint)
                .frame(width: 42, height: 42)
                .background(surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(edge) }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Word Relay").font(.system(size: 24, weight: .semibold))
                Text("\(model.lexicon.count.formatted()) English words")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(dim)
            }
            Spacer()
            Button { sheet = .settings } label: {
                Image(systemName: "gearshape").font(.system(size: 17, weight: .medium))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(PlainButtonStyle())
            .foregroundStyle(dim)
            .help("Settings")
            .accessibilityLabel("Settings")
        }
    }

    private var prompt: some View {
        HStack(alignment: .center, spacing: 13) {
            VStack(alignment: .leading, spacing: 5) {
                Text("CURRENT PREFIX")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(dim)
                    .tracking(1.4)
                Text(model.match.prefix.isEmpty || model.match.phase == .finished ? "—" : model.match.prefix.uppercased())
                    .font(.system(size: 48, weight: .bold, design: .monospaced))
                    .foregroundStyle(model.match.phase == .between ? dim : mint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.30)
                    .contentTransition(.identity)
                    .accessibilityLabel("Prefix \(model.match.prefix.uppercased())")
            }
            Spacer(minLength: 2)
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                timer
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(height: 106)
        .background(surface.gradient, in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(edge) }
    }

    private var timer: some View {
        let now = Dashboard.now
        let started = model.match.turnStarted ?? now
        let active = model.match.phase == .turn
        let gameSeconds = model.match.observedClock
        let sampleTime = model.match.clockObservedAt ?? now
        let estimate = Double(model.preferences.turnSeconds)
        let time = gameSeconds.map { $0 - (now - sampleTime) } ?? (estimate - (now - started))
        let total = max(estimate, gameSeconds ?? 0)
        let fraction = active ? min(1, max(0, time / total)) : 0
        let color = active && time < 3 ? amber : mint

        return VStack(alignment: .trailing, spacing: 7) {
            Text(active ? "\(max(0, time).formatted(.number.precision(.fractionLength(1))))s" : "—")
                .font(.system(size: 24, weight: .semibold, design: .monospaced))
                .foregroundStyle(active ? color : dim)
                .lineLimit(1)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(edge)
                    Capsule().fill(color).frame(width: geometry.size.width * fraction)
                }
            }
            .frame(width: 72, height: 3)
            Text(gameSeconds == nil || !active ? "TURN TIMER" : "GAME CLOCK")
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .tracking(0.65)
                .foregroundStyle(dim)
        }
        .accessibilityElement(children: .combine)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            let on = model.watch == .watching || model.watch == .starting
            Button {
                if on { model.stop() } else { model.start() }
            } label: {
                Label(on ? "Stop" : "Start", systemImage: on ? "stop.fill" : "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(minWidth: 68)
            }
            .buttonStyle(FillButton(major: true))
            .help(on ? "Stop scanning (Control–Shift–D)" : "Start scanning (Control–Shift–S)")
            HStack(spacing: 6) {
                Circle().fill(status.tint).frame(width: 6, height: 6)
                Text(status.label).font(.system(size: 12, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(status.tint)
            Spacer(minLength: 0)
        }
    }

    private var status: (label: String, tint: Color) {
        switch model.watch {
        case .stopped: return ("Scanner off", dim)
        case .failed: return ("Scanner unavailable", amber)
        case .starting: return ("Connecting…", mint)
        case .watching:
            switch model.match.phase {
            case .waiting: return ("Waiting for the next prompt", dim)
            case .turn: return ("Watching \(model.sourceName)", mint)
            case .between: return ("Waiting for tiles", dim)
            case .finished: return ("Match ended", amber)
            }
        }
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Suggestions").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button {
                    model.nextWords()
                    batch += 1
                } label: {
                    Label("Next \(model.preferences.wordOptions.count)", systemImage: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(FillButton(major: false, height: 25))
                .disabled(!model.match.canCycleSuggestions)
            }
            .padding(.bottom, 2)

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(model.match.suggestions, id: \.self) { word in
                        wordRow(word)
                    }
                    ForEach(0..<max(0, 5 - model.match.suggestions.count), id: \.self) { _ in
                        HStack {
                            Text("—").foregroundStyle(dim.opacity(0.60))
                            Spacer()
                        }
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .background(surface.opacity(0.60), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityHidden(true)
                    }
                }
            }
            .frame(height: 194)
            .id("\(model.match.turns)-\(model.match.prefix)-\(batch)")

            Text(suggestionNote)
                .font(.system(size: 11))
                .foregroundStyle(model.message == nil ? dim : amber)
                .lineLimit(2)
                .frame(height: 28, alignment: .topLeading)
                .padding(.top, 3)
                .accessibilityIdentifier("suggestionStatus")
        }
    }

    private var suggestionNote: String {
        if let message = model.message ?? model.answerStatus { return message }
        if let reason = model.match.finishReason { return reason }
        if let copied = model.copied { return "Copied \(copied)" }
        if model.match.prefix.isEmpty {
            return model.watch == .watching ? "Listening for the first tiles of the turn." :
                "Start scanning or enter a prefix below."
        }
        if model.match.suggestions.isEmpty { return "No available matches for \(model.match.prefix.uppercased())." }
        if model.match.suggestions.count > 5 {
            return "\(model.match.suggestions.count) suggestions. Scroll to see more."
        }
        return "Click a word to copy it."
    }

    private func wordRow(_ word: String) -> some View {
        HStack(spacing: 5) {
            copyWordButton(word)
            Button {
                model.recordPlayed(word)
            } label: {
                Image(systemName: "checkmark").frame(width: 14)
            }
            .buttonStyle(FillButton(major: false, height: 34))
            .help("Mark \(word) played")
            .accessibilityLabel("Mark \(word) played")
        }
    }

    private func copyWordButton(_ word: String) -> some View {
        Button {
            model.copy(word)
        } label: {
            HStack {
                Text(word)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 10)
                Image(systemName: model.copied == word ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(model.copied == word ? mint : dim)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(model.copied == word ? mint.opacity(0.6) : edge, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Copy \(word)")
        .accessibilityLabel("Copy \(word)")
        .contextMenu {
            Button("Mark played") { model.recordPlayed(word) }
        }
    }

    private var manual: some View {
        HStack(spacing: 7) {
            TextField("Enter letters", text: $entry)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 9)
                .frame(height: 32)
                .background(canvasColor, in: RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(edge) }
                .onSubmit(submit)
                .onChange(of: entry) { _, value in
                    let clean = String(value.filter { $0.isASCII && $0.isLetter }.uppercased().prefix(WordOptions.maximumWordLength))
                    if clean != value { entry = clean }
                }
            Button("Find", action: submit)
                .buttonStyle(FillButton(major: false))
                .disabled(entry.isEmpty)
            Button {
                model.loadImage()
            } label: {
                Image(systemName: "photo").frame(width: 15)
            }
            .buttonStyle(FillButton(major: false))
            .disabled(model.watch == .watching || model.watch == .starting)
            .help("Read letter tiles from a screenshot")
            .accessibilityLabel("Read screenshot")
        }
    }

    private var footer: some View {
        VStack(spacing: 9) {
            Rectangle().fill(edge).frame(height: 1)
            HStack {
                Button {
                    sheet = .history
                } label: {
                    Label("\(model.match.usedCount) played",
                          systemImage: "clock.arrow.circlepath")
                }
                .help("View played words and suggestion history")
                Spacer()
                Button {
                    model.newMatch()
                } label: {
                    Label("New match", systemImage: "arrow.counterclockwise")
                }
                .help("Clear word history and start over (Control–Shift–N)")
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(dim)
            if model.keyboardStatus == .needsPermission {
                Button("Enable Input Monitoring to track typing") { model.allowInputMonitoring() }
                    .buttonStyle(.link)
                    .lineLimit(1)
            } else if model.keyboardStatus == .unavailable {
                Text("Typing unavailable. Use the checkmark to mark a word.")
                    .font(.caption)
                    .foregroundStyle(amber)
            }
        }
    }

    private func submit() {
        model.lookup(entry)
        entry = ""
    }
}

private struct FillButton: ButtonStyle {
    let major: Bool
    var height: CGFloat = 32
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .frame(height: height)
            .foregroundStyle(major ? ink : bright)
            .background(major ? mint : surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(major ? .clear : edge) }
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.38)
            .contentShape(Rectangle())
    }
}

private struct SettingsView: View {
    @ObservedObject var model: Dashboard
    @Environment(\.dismiss) private var dismiss
    @State private var customDraft = ""
    @State private var showCustomEditor = false
    @State private var regionChoice = RegionChoice.tiles

    private enum RegionChoice: String, CaseIterable, Identifiable {
        case tiles = "Letter tiles"
        case played = "Played word"
        var id: Self { self }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Settings").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(FillButton(major: true))
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    sourceSettings
                    Divider()
                    timingSettings
                    Divider()
                    wordSettings
                    Divider()
                    trackingSettings
                    Divider()
                    areaSettings
                    Divider()
                    shortcutSettings
                }
                .padding(1)
            }
        }
        .padding(22)
        .frame(width: 548, height: 694)
        .background(canvasColor)
        .foregroundStyle(bright)
        .onAppear {
            model.refreshWindows()
            customDraft = model.preferences.wordOptions.custom.joined(separator: "\n")
        }
    }

    private var sourceSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Window").font(.headline)
            if CaptureSource.usesSystemPicker {
                Text("Click Start and pick the Roblox window to share.")
                    .font(.caption)
                    .foregroundStyle(dim)
            } else {
                legacySourcePicker
            }
            Toggle("Keep Word Relay above other windows", isOn: $model.preferences.floating)
        }
    }

    private var legacySourcePicker: some View {
        HStack {
            Picker("Capture source", selection: Binding(
                get: { model.sourceID },
                set: { model.selectWindow($0) }
            )) {
                Text("Roblox (automatic)").tag(nil as CGWindowID?)
                ForEach(model.windows) { window in
                    Text(window.name).tag(Optional(window.id))
                }
                if let choice = model.sourceID, !model.windows.contains(where: { $0.id == choice }) {
                    Text("Previous selection").tag(Optional(choice))
                }
            }
            .labelsHidden()
            Button("Refresh") { model.refreshWindows() }.buttonStyle(FillButton(major: false))
        }
    }

    private var timingSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Timing").font(.headline)
            Stepper(value: $model.preferences.turnSeconds, in: 1...120) {
                Text("Fallback turn timer · \(model.preferences.turnSeconds)s")
            }
            Stepper(value: $model.preferences.endSeconds, in: 5...120, step: 5) {
                Text("End match after \(model.preferences.endSeconds)s without letter tiles")
            }
            Text("Word Relay reads the full starting row. If letters flicker while the game clock is visible, the last prompt stays active.")
                .font(.caption)
                .foregroundStyle(dim)
        }
    }

    private var wordSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Suggestions").font(.headline)
            counter("Words per batch", value: Binding(
                get: { model.preferences.wordOptions.count },
                set: { model.preferences.suggestionCount = $0 }
            ), in: 1...100)
            counter("Custom words per batch", value: Binding(
                get: { model.preferences.wordOptions.customLimit },
                set: { model.preferences.customLimit = $0 }
            ), in: 0...100)
            Stepper(value: $model.preferences.minimumLength, in: 2...8) {
                Text("Minimum word length · \(model.preferences.minimumLength)")
            }

            DisclosureGroup("Custom words · \(model.preferences.wordOptions.custom.count)/100",
                            isExpanded: $showCustomEditor) {
                let words = WordOptions.customWords(from: customDraft)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Enter up to 100 words, separated by spaces, commas, or new lines.")
                        .font(.caption)
                        .foregroundStyle(dim)
                    TextEditor(text: $customDraft)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 105)
                        .scrollContentBackground(.hidden)
                        .padding(5)
                        .background(surface, in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("Custom words")
                    HStack {
                        Text("\(words.count) unique words")
                            .font(.caption)
                            .foregroundStyle(words.count > WordOptions.maximumCount ? amber : dim)
                        Spacer()
                        Button("Save words") { model.preferences.customWords = words }
                            .buttonStyle(FillButton(major: true, height: 27))
                            .disabled(words.count > WordOptions.maximumCount ||
                                      words == model.preferences.wordOptions.custom)
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    private func counter(_ label: String, value: Binding<Int>, in range: ClosedRange<Int>) -> some View {
        let bounded = Binding(
            get: { value.wrappedValue },
            set: { value.wrappedValue = min(range.upperBound, max(range.lowerBound, $0)) }
        )
        return HStack(spacing: 6) {
            Text(label)
            Spacer()
            TextField(label, value: bounded, format: .number)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 52)
            Stepper(value: bounded, in: range) { EmptyView() }.labelsHidden()
        }
    }

    private var trackingSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Played words").font(.headline)
            Toggle("Track words I submit in Roblox", isOn: Binding(
                get: { model.preferences.tracksKeyboard },
                set: { model.preferences.trackSubmissions = $0 }
            ))
            Text("Words you submit or mark as played are excluded from suggestions. You can undo an entry in match history.")
                .font(.caption)
                .foregroundStyle(dim)
            if model.preferences.tracksKeyboard {
                switch model.keyboardStatus {
                case .listening:
                    Label("Submission tracking on", systemImage: "checkmark.circle").foregroundStyle(mint)
                case .unavailable:
                    Text("Keyboard tracking is unavailable for this Roblox window.").foregroundStyle(amber)
                case .inactive, .needsPermission:
                    Button("Allow Input Monitoring") { model.allowInputMonitoring() }
                        .buttonStyle(FillButton(major: false))
                }
            }
        }
    }

    private var areaSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Scan areas").font(.headline)
            Picker("Scan area", selection: $regionChoice) {
                ForEach(RegionChoice.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(regionChoice == .tiles
                 ? "Draw a box around the letter tiles. Leave room for longer prefixes and turn animations."
                 : "Optional. Draw a box around a single last-played word if your game shows one on screen.")
                .font(.caption)
                .foregroundStyle(dim)
            HStack {
                Button(model.preview == nil ? "Preview window" : "Refresh preview") {
                    model.capturePreview()
                }
                .buttonStyle(FillButton(major: false))
                .disabled(model.previewBusy)
                if regionChoice == .tiles {
                    Button("Reset tile area") { model.preferences.region = .tiles }
                        .buttonStyle(FillButton(major: false))
                } else if model.preferences.playedRegion != nil {
                    Button("Clear played area") { model.preferences.playedRegion = nil }
                        .buttonStyle(FillButton(major: false))
                }
                if model.previewBusy { ProgressView().controlSize(.small) }
            }
            if let message = model.previewMessage {
                Text(message).font(.caption).foregroundStyle(amber)
            }
            if let image = model.preview {
                let tiles = regionChoice == .tiles
                RegionPreview(image: image, region: tiles ? model.preferences.region : model.preferences.playedRegion,
                              minimum: tiles ? CGSize(width: 0.09, height: 0.09)
                                             : CGSize(width: 0.038, height: 0.018)) { region in
                    if tiles { model.preferences.region = region }
                    else { model.preferences.playedRegion = region }
                }
                .id(regionChoice)
            }
        }
    }

    private var shortcutSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Global shortcuts").font(.headline)
            Group {
                shortcut("Start scanning", "⌃ ⇧ S")
                shortcut("Stop scanning", "⌃ ⇧ D")
                shortcut("New match", "⌃ ⇧ N")
                shortcut("Type an answer in Roblox", "⌃ ⇧ W")
            }
            Toggle("Type only the letters after the prompt", isOn: Binding(
                get: { model.preferences.skipsTypedPrefix },
                set: { model.preferences.typeSuffixOnly = $0 }
            ))
            Text("Press the answer shortcut on your turn. Word Relay can try another suggestion when it sees a new red X.")
                .font(.caption)
                .foregroundStyle(dim)
            if !model.hotkeysAvailable {
                Text("One or more shortcuts are used by another app. The window controls are still available.")
                    .font(.caption).foregroundStyle(amber)
            }
            if !CaptureSource.usesSystemPicker {
                Button("Open Screen Recording settings") { model.openScreenSettings() }
                    .buttonStyle(FillButton(major: false))
            }
        }
    }

    private func shortcut(_ name: String, _ keys: String) -> some View {
        HStack {
            Text(name).foregroundStyle(dim)
            Spacer()
            Text(keys).monospaced().foregroundStyle(mint)
        }
        .font(.system(size: 12))
    }
}

private struct RegionPreview: View {
    let image: CGImage
    let region: ScanRegion?
    let minimum: CGSize
    let onChange: (ScanRegion) -> Void
    @State private var draft: ScanRegion?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let draw = draft ?? region
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(width: width, height: height)
                if let draw {
                    Rectangle().fill(mint.opacity(0.12))
                        .overlay { Rectangle().strokeBorder(mint, lineWidth: 2) }
                        .frame(width: width * draw.width, height: height * draw.height)
                        .offset(x: width * draw.x, y: height * draw.y)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 4).onChanged { value in
                draft = selection(value, size: geometry.size)
            }.onEnded { value in
                let area = selection(value, size: geometry.size)
                if area.width >= minimum.width, area.height >= minimum.height { onChange(area) }
                draft = nil
            })
        }
        .aspectRatio(Double(image.width) / Double(image.height), contentMode: .fit)
        .accessibilityLabel("Selected window. Drag to set the scan area.")
    }

    private func selection(_ value: DragGesture.Value, size: CGSize) -> ScanRegion {
        let x1 = min(max(0, value.startLocation.x / size.width), 1)
        let y1 = min(max(0, value.startLocation.y / size.height), 1)
        let x2 = min(max(0, value.location.x / size.width), 1)
        let y2 = min(max(0, value.location.y / size.height), 1)
        return ScanRegion(x: min(x1, x2), y: min(y1, y2), width: abs(x1 - x2), height: abs(y1 - y2))
    }
}

private struct HistoryView: View {
    @ObservedObject var model: Dashboard
    @Environment(\.dismiss) private var dismiss
    @State private var showingPlayed = true
    @State private var manualWord = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Match history").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(FillButton(major: true))
            }

            Picker("History", selection: $showingPlayed) {
                Text("Played (\(model.match.played.count))").tag(true)
                Text("Shown (\(model.match.history.count))").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if showingPlayed {
                HStack {
                    TextField("Word played", text: $manualWord)
                        .onSubmit(markPlayed)
                    Button("Mark played", action: markPlayed)
                        .buttonStyle(FillButton(major: false, height: 27))
                        .disabled(WordOptions.normalize(manualWord) == nil)
                }
                if let status = keyboardNote {
                    Text(status).font(.caption).foregroundStyle(dim)
                }
                if model.match.played.isEmpty {
                    Text("Submissions, marked words, and words seen on screen appear here.")
                        .font(.callout).foregroundStyle(dim)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(model.match.played.reversed())) { entry in
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(entry.word).font(.body.weight(.semibold))
                                        Text(entry.source.rawValue).font(.caption).foregroundStyle(dim)
                                    }
                                    Spacer()
                                    Button("Undo") { model.removePlayed(entry.word) }
                                        .buttonStyle(FillButton(major: false, height: 24))
                                        .accessibilityLabel("Undo played word \(entry.word)")
                                }
                                .padding(.vertical, 7)
                                Divider()
                            }
                        }
                    }
                }
            } else if model.match.history.isEmpty {
                Text("Words appear here as you get suggestions.").foregroundStyle(dim)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.match.history.reversed()), id: \.self) { word in
                            Text(word).frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 7)
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(22)
        .frame(width: 385, height: 433)
        .background(canvasColor)
        .foregroundStyle(bright)
    }

    private var keyboardNote: String? {
        switch model.keyboardStatus {
        case .listening: return "Submission tracking is on. Press Return to log an entered word."
        case .needsPermission: return "Allow Input Monitoring in Settings to log words you type."
        case .unavailable: return "Use Mark played to log words for this window."
        case .inactive: return nil
        }
    }

    private func markPlayed() {
        model.recordPlayed(manualWord)
        manualWord = ""
    }
}
