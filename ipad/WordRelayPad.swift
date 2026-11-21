import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

@main
struct WordRelayPad: App {
    var body: some Scene {
        WindowGroup { RelayPadView() }
    }
}

@MainActor
private final class PadModel: ObservableObject {
    @Published var match = Match()
    @Published var notice: String?
    @Published var loading = false
    @AppStorage("padBatchSize") var batchSize = 5
    @AppStorage("padMinimumLength") var minimumLength = 3
    @AppStorage("padCustomLimit") var customLimit = 100
    @AppStorage("padCustomWords") var customText = ""
    @AppStorage("padTurnSeconds") var turnSeconds = 10

    let lexicon: Lexicon

    init() {
        func dictionary(_ name: String) -> String {
            guard let url = Bundle.main.url(forResource: name, withExtension: "txt") else { return "" }
            return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        lexicon = Lexicon(contents: dictionary("words"), extended: dictionary("words-extra"))
    }

    var options: WordOptions {
        WordOptions(minimumLength: minimumLength, count: batchSize,
                    custom: Array(WordOptions.customWords(from: customText).prefix(100)), customLimit: customLimit)
    }

    func lookup(_ letters: String, seconds: Double? = nil) {
        let prefix = String(letters.lowercased().filter { $0.isASCII && $0.isLetter }.prefix(40))
        guard !prefix.isEmpty else { return }
        notice = nil
        match.startTurn(prefix, now: ProcessInfo.processInfo.systemUptime, seconds: seconds,
                        lexicon: lexicon, options: options)
    }

    func importImage(_ data: Data) async {
        if loading { return }
        loading = true
        defer { loading = false }
        let row = await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let pixels = Raster(image: image) else { return nil as Reading? }
            return TileReader().read(pixels, region: .tiles, now: ProcessInfo.processInfo.systemUptime,
                                     inspectResults: false)
        }.value
        if let row, let prefix = row.prefix { lookup(prefix, seconds: row.seconds) }
        else { notice = "No complete letter row was found. You can enter the letters below." }
    }

    func copy(_ word: String) {
        UIPasteboard.general.string = word
        notice = "Copied \(word)"
    }

    func record(_ word: String) {
        match.record(word, source: .manual, lexicon: lexicon, options: options)
    }

    func undo(_ word: String) {
        match.removePlayed(word, lexicon: lexicon, options: options)
    }
}

private let canvasColor = Color(red: 0.059, green: 0.095, blue: 0.112)
private let panel = Color(red: 0.104, green: 0.164, blue: 0.174)
private let muted = Color(red: 0.61, green: 0.73, blue: 0.70)
private let mint = Color(red: 0.68, green: 0.97, blue: 0.83)

private struct RelayPadView: View {
    @StateObject private var model = PadModel()
    @State private var entry = ""
    @State private var photo: PhotosPickerItem?
    @State private var showFiles = false
    @State private var showHistory = false
    @State private var showSettings = false

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 23) {
                    header
                    let layout = geometry.size.width >= 760 ? AnyLayout(HStackLayout(alignment: .top, spacing: 20)) :
                        AnyLayout(VStackLayout(alignment: .leading, spacing: 17))
                    layout {
                        controls.frame(maxWidth: .infinity, alignment: .leading)
                        suggestions.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    footer
                }
                .frame(maxWidth: 1000)
                .padding(.horizontal, geometry.size.width > 700 ? 42 : 21)
                .padding(.vertical, 34)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(canvasColor.ignoresSafeArea())
        .foregroundStyle(.white)
        .tint(mint)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showHistory) { PadHistory(model: model) }
        .sheet(isPresented: $showSettings, onDismiss: {
            model.match.restartSuggestions(lexicon: model.lexicon, options: model.options)
        }) { PadSettings(model: model) }
        .onChange(of: photo) { _, selection in
            Task {
                if let data = try? await selection?.loadTransferable(type: Data.self) {
                    await model.importImage(data)
                }
                if selection == photo { photo = nil }
            }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image]) { result in
            guard let url = try? result.get() else { return }
            Task {
                let granted = url.startAccessingSecurityScopedResource()
                defer { if granted { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) { await model.importImage(data) }
                else { model.notice = "That image could not be opened." }
            }
        }
        #if DEBUG
        .task {
            let args = ProcessInfo.processInfo.arguments
            if let index = args.firstIndex(of: "--qa-image"), args.indices.contains(index + 1),
               let data = FileManager.default.contents(atPath: args[index + 1]) {
                await model.importImage(data)
                NSLog("Word Relay QA prefix=%@ count=%d", model.match.prefix, model.match.suggestions.count)
            }
        }
        #endif
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Image("RelayMark").resizable().frame(width: 52, height: 52).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Word Relay").font(.system(size: 34, weight: .semibold))
                Text("\(model.lexicon.count.formatted()) English words").font(.subheadline).foregroundStyle(muted)
            }
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "gearshape").font(.title3).frame(width: 38, height: 38)
            }
            .accessibilityLabel("Settings")
            .buttonStyle(.bordered)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 19) {
            VStack(alignment: .leading, spacing: 8) {
                Text("CURRENT PREFIX").font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(2).foregroundStyle(muted)
                HStack(alignment: .firstTextBaseline) {
                    Text(model.match.prefix.isEmpty ? "—" : model.match.prefix.uppercased())
                        .font(.system(size: 52, weight: .bold, design: .monospaced))
                        .lineLimit(1).minimumScaleFactor(0.24).foregroundStyle(mint)
                        .accessibilityIdentifier("currentPrefix")
                    Spacer()
                    countdown
                }
            }
            .padding(18).background(panel, in: RoundedRectangle(cornerRadius: 16))

            HStack(spacing: 9) {
                TextField("Enter starting letters", text: $entry)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit(submit)
                    .padding(12).background(panel, in: RoundedRectangle(cornerRadius: 10))
                Button("Find", action: submit)
                    .font(.headline).buttonStyle(.borderedProminent)
                    .foregroundStyle(canvasColor)
                    .disabled(entry.isEmpty)
            }

            HStack {
                PhotosPicker(selection: $photo, matching: .images) {
                    Label("Photos", systemImage: "photo")
                }
                Button { showFiles = true } label: { Label("Files", systemImage: "folder") }
                if model.loading { ProgressView() }
            }
            .buttonStyle(.bordered)
            .disabled(model.loading)
            Text(model.notice ?? "Import an image of the game or enter the starting letters.")
                .font(.footnote).foregroundStyle(muted)
        }
    }

    private var countdown: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            Text(countdownLabel)
                .font(.system(.title2, design: .monospaced))
                .foregroundStyle(muted)
        }
    }

    private var countdownLabel: String {
        let now = ProcessInfo.processInfo.systemUptime
        let seconds: TimeInterval
        if let observed = model.match.observedClock, let observedAt = model.match.clockObservedAt {
            seconds = observed - (now - observedAt)
        } else if let started = model.match.turnStarted {
            seconds = Double(model.turnSeconds) - (now - started)
        } else {
            return "—"
        }
        return max(0, seconds).formatted(.number.precision(.fractionLength(1))) + "s"
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Suggestions").font(.title3.weight(.semibold))
                Spacer()
                Button("Next \(model.batchSize)") {
                    model.match.nextWords(lexicon: model.lexicon, options: model.options)
                }.buttonStyle(.bordered).disabled(!model.match.canCycleSuggestions)
            }
            if model.match.suggestions.isEmpty {
                Text(model.match.prefix.isEmpty ? "Suggestions appear after a lookup." : "No available matches for this prefix.")
                    .foregroundStyle(muted).padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(panel, in: RoundedRectangle(cornerRadius: 9))
            }
            ForEach(model.match.suggestions, id: \.self) { word in
                HStack(spacing: 8) {
                    Button { model.copy(word) } label: {
                        HStack {
                            Text(word).font(.system(.headline, design: .monospaced)).foregroundStyle(.white)
                            Spacer()
                            Image(systemName: "doc.on.doc").foregroundStyle(muted)
                        }.padding(13).background(panel, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .contextMenu { Button("Mark played") { model.record(word) } }
                    Button { model.record(word) } label: {
                        Image(systemName: "checkmark")
                            .frame(width: 46, height: 46)
                            .background(panel, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Mark \(word) played")
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button {
                showHistory = true
            } label: {
                Label("\(model.match.usedCount) played",
                      systemImage: "clock.arrow.circlepath")
            }
            Spacer()
            Button {
                model.match = Match()
                model.notice = nil
            } label: {
                Label("New match", systemImage: "arrow.counterclockwise")
            }
        }
        .font(.subheadline)
        .buttonStyle(.bordered)
    }

    private func submit() {
        model.lookup(entry)
        entry = ""
    }
}

private struct PadSettings: View {
    @ObservedObject var model: PadModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Suggestions") {
                    Stepper("Words per batch · \(model.batchSize)", value: $model.batchSize, in: 1...100)
                    Stepper("Custom words per batch · \(model.customLimit)", value: $model.customLimit, in: 0...100)
                    Stepper("Minimum word length · \(model.minimumLength)", value: $model.minimumLength, in: 2...8)
                    Stepper("Fallback timer · \(model.turnSeconds)s", value: $model.turnSeconds, in: 1...120)
                }
                Section("Custom words") {
                    TextEditor(text: $draft).frame(minHeight: 130).accessibilityLabel("Custom words")
                    Text("\(WordOptions.customWords(from: draft).count) / 100 unique words")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        model.customText = WordOptions.customWords(from: draft).joined(separator: "\n")
                        dismiss()
                    }
                    .disabled(WordOptions.customWords(from: draft).count > 100)
                }
            }
            .onAppear { draft = model.customText }
        }
    }
}

private struct PadHistory: View {
    @ObservedObject var model: PadModel
    @Environment(\.dismiss) private var dismiss
    @State private var entry = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Played") {
                    HStack {
                        TextField("Word played", text: $entry).autocorrectionDisabled()
                        Button("Mark") {
                            model.record(entry)
                            entry = ""
                        }.disabled(WordOptions.normalize(entry) == nil)
                    }
                    ForEach(Array(model.match.played.reversed())) { word in
                        HStack {
                            Text(word.word)
                            Spacer()
                            Button("Undo") { model.undo(word.word) }
                        }
                    }
                }
                Section("Shown") {
                    ForEach(Array(model.match.history.reversed()), id: \.self) { Text($0) }
                }
            }
            .navigationTitle("Match history")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
