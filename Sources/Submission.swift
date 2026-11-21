import AppKit
import Carbon

enum AnswerTyping {
    static let eventTag: Int64 = 0x57524C59
    private static let keys = [
        kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G,
        kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N,
        kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U,
        kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y, kVK_ANSI_Z
    ]

    static func type(_ text: String, in pid: pid_t) -> Bool {
        guard !text.isEmpty, CGPreflightPostEventAccess(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              CGEventSource.flagsState(.combinedSessionState)
                .intersection([.maskCommand, .maskControl, .maskShift, .maskAlternate]).isEmpty,
              text.utf8.allSatisfy({ (97...122).contains($0) }) else { return false }
        let codes = text.utf8.map { keys[Int($0) - 97] } + [kVK_Return]
        let source = CGEventSource(stateID: .privateState)
        var events: [CGEvent] = []
        for key in codes {
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: down)
                else { return false }
                event.flags = []
                event.setIntegerValueField(.eventSourceUserData, value: eventTag)
                events.append(event)
            }
        }
        for event in events { event.postToPid(pid) }
        return true
    }
}

// The draft exists only during an active turn in the selected Roblox process.
struct WordDraft {
    private var letters: [Character] = []
    private var cursor = 0
    private var selected = false
    private var invalid = false

    mutating func insert(_ text: String) {
        if selected { clear() }
        let incoming = Array(text.lowercased())
        guard !incoming.isEmpty else { return }
        guard !invalid, letters.count + incoming.count <= WordOptions.maximumWordLength,
              incoming.allSatisfy({ $0.isASCII && $0.isLetter }) else {
            clear()
            invalid = true
            return
        }
        letters.insert(contentsOf: incoming, at: cursor)
        cursor += incoming.count
    }

    mutating func selectAll() {
        selected = true
    }

    mutating func delete(backwards: Bool) {
        if selected { clear(); return }
        if backwards, cursor > 0 {
            cursor -= 1
            letters.remove(at: cursor)
        } else if !backwards, cursor < letters.count {
            letters.remove(at: cursor)
        }
    }

    mutating func move(_ direction: Int) {
        selected = false
        cursor = min(letters.count, max(0, cursor + direction))
    }

    mutating func moveToEdge(end: Bool) {
        selected = false
        cursor = end ? letters.count : 0
    }

    mutating func submit() -> String? {
        let result = invalid || letters.isEmpty ? nil : String(letters)
        clear()
        return result
    }

    mutating func clear() {
        letters.removeAll(keepingCapacity: true)
        cursor = 0
        selected = false
        invalid = false
    }
}

@MainActor
final class SubmissionListener {
    private var tap: CFMachPort?
    private var runSource: CFRunLoopSource?
    private var draft = WordDraft()
    private var previousTurn = false
    private let pid: pid_t
    private let canRead: () -> Bool
    private let pastedSuggestion: () -> String?
    private let submit: (String, Bool) -> Void

    init(pid: pid_t, canRead: @escaping () -> Bool, pastedSuggestion: @escaping () -> String?,
         submit: @escaping (String, Bool) -> Void) {
        self.pid = pid
        self.canRead = canRead
        self.pastedSuggestion = pastedSuggestion
        self.submit = submit
    }

    func start() -> Bool {
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
        guard let tap = CGEvent.tapCreateForPid(
            pid: pid, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask,
            callback: { _, type, event, data in
                if let data {
                    let listener = Unmanaged<SubmissionListener>.fromOpaque(data).takeUnretainedValue()
                    MainActor.assumeIsolated { listener.process(type, event: event) }
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return false }
        self.tap = tap
        runSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runSource, .commonModes) }
        tap = nil
        runSource = nil
        clearDraft()
    }

    func clearDraft() {
        previousTurn = false
        draft.clear()
    }

    func turnChanged() {
        if previousTurn { clearDraft() }
        previousTurn = true
    }

    private func process(_ type: CGEventType, event: CGEvent) {
        if event.getIntegerValueField(.eventSourceUserData) == AnswerTyping.eventTag { return }
        if (type == .tapDisabledByTimeout || type == .tapDisabledByUserInput), let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
            clearDraft()
            return
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid, canRead() else {
            clearDraft()
            return
        }
        if type == .leftMouseDown { clearDraft(); return }
        guard type == .keyDown else { return }

        let key = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let isReturn = key == kVK_Return || key == kVK_ANSI_KeypadEnter
        if previousTurn && !isReturn { clearDraft() }
        let flags = event.flags
        if flags.contains(.maskCommand) {
            switch key {
            case kVK_ANSI_A: draft.selectAll()
            case kVK_ANSI_V:
                if let text = pastedSuggestion() { draft.insert(text) } else { draft.clear() }
            case kVK_ANSI_X: draft.clear()
            default: break
            }
            return
        }
        guard !flags.contains(.maskControl), !flags.contains(.maskAlternate) else { return }
        switch key {
        case kVK_Return, kVK_ANSI_KeypadEnter:
            let wasPreviousTurn = previousTurn
            previousTurn = false
            if let word = draft.submit() { submit(word, wasPreviousTurn) }
        case kVK_Delete: draft.delete(backwards: true)
        case kVK_ForwardDelete: draft.delete(backwards: false)
        case kVK_LeftArrow: draft.move(-1)
        case kVK_RightArrow: draft.move(1)
        case kVK_Home: draft.moveToEdge(end: false)
        case kVK_End: draft.moveToEdge(end: true)
        case kVK_Escape, kVK_Tab: draft.clear()
        default:
            var chars = [UniChar](repeating: 0, count: 8)
            var length = 0
            event.keyboardGetUnicodeString(maxStringLength: chars.count, actualStringLength: &length,
                                           unicodeString: &chars)
            if length > 0 { draft.insert(String(decoding: chars.prefix(length), as: UTF16.self)) }
        }
    }
}
