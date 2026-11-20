import Foundation

struct WordOptions {
    var minimumLength = 3
    var count = 5
    var custom: [String] = []
    var customLimit = 100

    static let maximumCount = 100
    static let maximumWordLength = 40

    static func normalize(_ value: String) -> String? {
        let word = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard (2...maximumWordLength).contains(word.utf8.count),
              word.utf8.allSatisfy({ (97...122).contains($0) }) else { return nil }
        return word
    }

    static func customWords(from text: String) -> [String] {
        var seen: Set<String> = []
        return text.split { $0.isWhitespace || $0 == "," }
            .compactMap { normalize(String($0)) }
            .filter { seen.insert($0).inserted }
    }
}

struct Lexicon {
    let count: Int
    private let index: [String: [String]]

    init(contents: String, extended: String = "") {
        let words = Set(contents.split(whereSeparator: \.isNewline).map(String.init))
        let extra = Set(extended.split(whereSeparator: \.isNewline).map(String.init)).subtracting(words)
        var index: [String: [String]] = [:]
        for word in Self.rank(words) + Self.rank(extra) {
            let bytes = Array(word.utf8.prefix(5))
            for length in 1...bytes.count {
                let prefix = String(decoding: bytes.prefix(length), as: UTF8.self)
                index[prefix, default: []].append(word)
            }
        }
        self.index = index
        count = words.count + extra.count
    }

    func matching(_ prefix: String, excluding blocked: Set<String>, options: WordOptions,
                  limit: Int, current: [String]) -> [String] {
        guard !prefix.isEmpty, limit > 0 else { return [] }
        let custom = Set(options.custom)
        let eligible: (String) -> Bool = { word in
            word.utf8.count >= options.minimumLength && !blocked.contains(word)
        }
        let pick = options.custom.lazy.filter { $0.hasPrefix(prefix) && eligible($0) }
        let key = String(prefix.prefix(5))
        let needsFullMatch = key != prefix
        let dictionary = (index[key] ?? []).lazy.filter {
            !custom.contains($0) && eligible($0) && (!needsFullMatch || $0.hasPrefix(prefix))
        }
        let favoritesUsed = current.lazy.filter { custom.contains($0) }.count
        let customRoom = max(0, options.customLimit - favoritesUsed)
        let favorites = Array(pick.prefix(min(limit, customRoom)))
        return favorites + Array(dictionary.prefix(limit - favorites.count))
    }

    func contains(_ word: String) -> Bool {
        index[String(word.prefix(5))]?.contains(word) == true
    }

    private static func rank(_ words: Set<String>) -> [String] {
        let scored: [(word: String, score: Int)] = words.map { ($0, ranking($0)) }
        return scored.sorted { first, second in
            if first.score == second.score { return first.word < second.word }
            return first.score < second.score
        }.map(\.word)
    }

    private static func ranking(_ word: String) -> Int {
        let inflectionPenalty = word.hasSuffix("s") || word.hasSuffix("ed") || word.hasSuffix("ing") ? 3 : 0
        return word.utf8.count + inflectionPenalty
    }
}

struct Reading {
    let prefix: String?
    var tilesPresent = true
    var seconds: Double? = nil
    var result: String? = nil
    var playedWord: String? = nil
    var clockVisible: Bool? = nil
}

enum PlayedSource: String {
    case submitted = "Submitted"
    case onScreen = "Seen on screen"
    case confirmed = "Submitted · seen on screen"
    case manual = "Marked manually"

    func merged(with observation: PlayedSource) -> PlayedSource {
        switch (self, observation) {
        case (.submitted, .onScreen), (.onScreen, .submitted): return .confirmed
        case (.onScreen, .manual): return .manual
        default: return self
        }
    }
}

struct PlayedWord: Identifiable, Equatable {
    let word: String
    let source: PlayedSource
    var id: String { word }
}

struct Match {
    enum Phase: Equatable {
        case waiting, turn, between, finished
    }

    var phase = Phase.waiting
    var prefix = ""
    var suggestions: [String] = []
    private(set) var canCycleSuggestions = false
    private var earlierBatches: Set<String> = []
    var shown: Set<String> = []
    var history: [String] = []
    var played: [PlayedWord] = []
    private var usedWords: Set<String> = []
    var usedCount: Int { usedWords.count }
    private(set) var previousPrefix = ""
    var turns = 0
    var finishReason: String?
    var turnStarted: TimeInterval?
    var observedClock: Double?
    var clockObservedAt: TimeInterval?
    private var clockJump: (seconds: Double, time: TimeInterval)?
    private var clockResetAt: TimeInterval?
    private var candidate = ""
    private var candidateFrames = 0
    private var candidateSince = 0.0
    private var missingSince: TimeInterval?
    private var lostHUDSince: TimeInterval?
    private var lastClockEvidence: TimeInterval?
    private var transitionGap = 0.0
    private var finishedAt: TimeInterval?
    private var stableTypedWord: String?

    mutating func ingest(
        _ reading: Reading, now: TimeInterval, endAfter: Double, lexicon: Lexicon,
        options: WordOptions = WordOptions()
    ) {
        if let result = reading.result {
            if phase == .turn || phase == .between { finish(result, now: now) }
            candidateFrames = 0
            return
        }

        let liveClock = reading.clockVisible == true || ((reading.seconds ?? 0) > 0)
        if liveClock {
            lastClockEvidence = now
            lostHUDSince = nil
            if phase == .between { phase = .turn }
        }
        if let seconds = reading.seconds { observeClock(seconds, now: now) }

        guard let observed = reading.prefix?.lowercased() else {
            candidateFrames = 0
            if !reading.tilesPresent, phase == .turn || phase == .between {
                missingSince = missingSince ?? now
                let gap = now - (missingSince ?? now)
                if !liveClock, reading.clockVisible == false, lastClockEvidence != nil {
                    lostHUDSince = lostHUDSince ?? now
                }
                if hasLiveClock(at: now) { return }
                let hudGone = lostHUDSince.map { now - $0 >= min(endAfter, 3) } ?? false
                if hudGone || gap >= endAfter {
                    finish(hudGone ? "Game screen closed" : "No letter tiles for \(Int(endAfter))s", now: now)
                } else if gap >= 0.60, !countdownIsRunning(at: now) {
                    phase = .between
                }
            }
            return
        }

        if let missingSince { transitionGap = now - missingSince }
        missingSince = nil
        lostHUDSince = nil

        if candidateFrames > 0 && observed == candidate {
            candidateFrames = min(candidateFrames + 1, 8)
        } else {
            candidate = observed
            candidateFrames = 1
            candidateSince = now
        }
        guard candidateFrames >= 2 else { return }

        if phase == .finished {
            guard now - (finishedAt ?? now) >= 0.65 else { return }
            self = Match()
            if liveClock { lastClockEvidence = now }
        }

        let reset = clockResetAt.map { now - $0 < 1.5 } ?? false
        let gap = transitionGap >= 0.40
        let same = observed == prefix
        let growing = !prefix.isEmpty && !same && observed.hasPrefix(prefix)
        let shrinking = !same && prefix.hasPrefix(observed)
        let carryover = stableTypedWord.map {
            $0 != observed && observed != prefix && $0.hasSuffix(observed)
        } ?? false
        let changed = !same && !growing && !shrinking
        let distinct = changed && candidateFrames >= 3 && now - candidateSince >= 0.19

        // A settled row can have any length. Typing grows the active row; a new
        // turn can legitimately start with those same letters plus more tiles.
        let freshReset = reset && (!growing || candidateSince >= (clockResetAt ?? now) - 0.50)
        let newPrompt = phase == .waiting || freshReset || carryover || distinct ||
            (gap && (changed || phase == .between))
        if newPrompt {
            if carryover, let word = stableTypedWord {
                record(word, source: .onScreen, lexicon: lexicon, options: options)
            }
            let seconds = reading.seconds ?? observedClock.flatMap { sample in
                clockObservedAt.flatMap { time in now - time <= 0.38 ? max(0, sample - (now - time)) : nil }
            }
            startTurn(observed, now: now, seconds: seconds, lexicon: lexicon, options: options)
        } else {
            if growing, lexicon.contains(observed) || options.custom.contains(observed) {
                stableTypedWord = observed
            }
            if phase == .between { phase = .turn }
            transitionGap = 0
        }
    }

    func hasLiveClock(at now: TimeInterval) -> Bool {
        lastClockEvidence.map { now - $0 <= 1.05 } ?? false
    }

    private func countdownIsRunning(at now: TimeInterval) -> Bool {
        guard let observedClock, let clockObservedAt else { return false }
        return observedClock > (now - clockObservedAt)
    }

    private mutating func observeClock(_ seconds: Double, now: TimeInterval) {
        guard let oldClock = observedClock, let last = clockObservedAt else {
            observedClock = seconds
            clockObservedAt = now
            return
        }
        let elapsed = now - last
        let projected = max(0, oldClock - elapsed)
        let jumpsUp = seconds > oldClock + 0.70 || (elapsed > 0.85 && seconds >= oldClock - 0.2 && seconds > projected + 1.1)
        if jumpsUp {
            if let jump = clockJump, now - jump.time <= 1.2,
               (jump.seconds - 1.8...jump.seconds + 0.35).contains(seconds) {
                clockResetAt = now
                observedClock = seconds
                clockObservedAt = now
                clockJump = nil
            } else {
                clockJump = (seconds, now)
            }
        } else {
            clockJump = nil
            if seconds <= oldClock + 0.45 && seconds >= projected - 2.0 {
                observedClock = seconds
                clockObservedAt = now
            }
        }
    }

    mutating func startTurn(_ letters: String, now: TimeInterval, seconds: Double?, lexicon: Lexicon, options: WordOptions = WordOptions()) {
        previousPrefix = prefix
        prefix = letters.lowercased()
        phase = .turn
        turns += 1
        turnStarted = now
        observedClock = seconds
        clockObservedAt = seconds == nil ? nil : now
        clockJump = nil
        clockResetAt = nil
        transitionGap = 0
        stableTypedWord = nil
        finishReason = nil
        restartSuggestions(lexicon: lexicon, options: options)
    }

    mutating func nextWords(lexicon: Lexicon, options: WordOptions = WordOptions()) {
        guard canCycleSuggestions else { return }
        earlierBatches.formUnion(suggestions)
        suggestions = []
        fillSuggestions(lexicon: lexicon, options: options)
        if suggestions.isEmpty { restartSuggestions(lexicon: lexicon, options: options) }
    }

    mutating func restartSuggestions(lexicon: Lexicon, options: WordOptions) {
        earlierBatches.removeAll()
        suggestions = []
        fillSuggestions(lexicon: lexicon, options: options)
    }

    mutating func fillSuggestions(lexicon: Lexicon, options: WordOptions) {
        guard phase == .turn || phase == .between else { return }
        let capacity = min(WordOptions.maximumCount, max(1, options.count))
        let custom = Set(options.custom)
        var customRoom = options.customLimit
        var retained: [String] = []
        for word in suggestions where word.utf8.count >= options.minimumLength && !usedWords.contains(word) {
            if retained.count == capacity { break }
            if custom.contains(word) {
                guard customRoom > 0 else { continue }
                customRoom -= 1
            }
            retained.append(word)
        }
        suggestions = retained
        let added = lexicon.matching(prefix, excluding: usedWords.union(earlierBatches).union(suggestions),
                                     options: options, limit: capacity - suggestions.count, current: suggestions)
        suggestions.append(contentsOf: added)
        for word in added where shown.insert(word).inserted { history.append(word) }
        canCycleSuggestions = !lexicon.matching(prefix, excluding: usedWords.union(suggestions),
                                                options: options, limit: 1, current: []).isEmpty
    }

    mutating func record(_ word: String, source: PlayedSource, lexicon: Lexicon, options: WordOptions) {
        guard let word = WordOptions.normalize(word) else { return }
        if let index = played.firstIndex(where: { $0.word == word }) {
            let merged = played[index].source.merged(with: source)
            played[index] = PlayedWord(word: word, source: merged)
        } else {
            played.append(PlayedWord(word: word, source: source))
        }
        guard source != .onScreen, usedWords.insert(word).inserted else { return }
        fillSuggestions(lexicon: lexicon, options: options)
        if suggestions.isEmpty, !earlierBatches.isEmpty {
            restartSuggestions(lexicon: lexicon, options: options)
        }
    }

    mutating func removePlayed(_ word: String, lexicon: Lexicon, options: WordOptions) {
        played.removeAll { $0.word == word }
        if usedWords.remove(word) != nil {
            restartSuggestions(lexicon: lexicon, options: options)
        }
    }

    mutating func finish(_ reason: String, now: TimeInterval) {
        self = Match()
        phase = .finished
        finishReason = reason
        finishedAt = now
    }

    mutating func resume() {
        missingSince = nil
        lostHUDSince = nil
        lastClockEvidence = nil
        transitionGap = 0
        candidateFrames = 0
        clockJump = nil
        clockResetAt = nil
        observedClock = nil
        clockObservedAt = nil
        stableTypedWord = nil
    }
}
