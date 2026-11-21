import AppKit
import Carbon
import SwiftUI

private final class GlobalShortcuts {
    private var handler: EventHandlerRef?
    private var references: [EventHotKeyRef] = []
    private let run: (UInt32) -> Void
    private let signature: OSType = 0x57524C59
    private(set) var registered = false

    init(run: @escaping (UInt32) -> Void) {
        self.run = run
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard result == noErr else { return result }
            let shortcuts = Unmanaged<GlobalShortcuts>.fromOpaque(context).takeUnretainedValue()
            guard id.signature == shortcuts.signature else { return OSStatus(eventNotHandledErr) }
            shortcuts.run(id.id)
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard result == noErr else { return }
        let keys = [kVK_ANSI_S, kVK_ANSI_D, kVK_ANSI_N, kVK_ANSI_W]
        let modifiers = UInt32(controlKey | shiftKey)
        for (index, key) in keys.enumerated() {
            var reference: EventHotKeyRef?
            let id = EventHotKeyID(signature: signature, id: UInt32(index + 1))
            if RegisterEventHotKey(UInt32(key), modifiers, id, GetApplicationEventTarget(), 0, &reference) == noErr,
               let reference {
                references.append(reference)
            }
        }
        registered = references.count == keys.count
    }

    deinit {
        references.forEach { UnregisterEventHotKey($0) }
        if let handler { RemoveEventHandler(handler) }
    }
}

@MainActor
private final class WordRelayDelegate: NSObject, NSApplicationDelegate {
    private let dashboard = Dashboard()
    private var window: NSWindow?
    private var shortcuts: GlobalShortcuts?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenu()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 386, height: 646),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Word Relay"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(srgbRed: 0.065, green: 0.102, blue: 0.116, alpha: 1)
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: DashboardView(model: dashboard))
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        dashboard.setFloating = { [weak window] enabled in
            window?.level = enabled ? .floating : .normal
        }
        dashboard.setFloating?(dashboard.preferences.floating)

        if let visible = NSScreen.main?.visibleFrame {
            window.setFrameTopLeftPoint(CGPoint(x: visible.maxX - window.frame.width - 22, y: visible.maxY - 23))
        } else {
            window.center()
        }
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let shortcuts = GlobalShortcuts { [weak self] action in
            DispatchQueue.main.async {
                switch action {
                case 1: self?.dashboard.start()
                case 2: self?.dashboard.stop()
                case 3: self?.dashboard.newMatch()
                case 4: self?.dashboard.requestAnswer()
                default: break
                }
            }
        }
        self.shortcuts = shortcuts
        if !shortcuts.registered { dashboard.disableHotkeyIndicator() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { window?.makeKeyAndOrderFront(nil) }
        return true
    }

    private func setupMenu() {
        let menuBar = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Word Relay")
        appMenu.addItem(withTitle: "About Word Relay",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Word Relay", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Word Relay", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menuBar.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        menuBar.addItem(editItem)

        let scanItem = NSMenuItem()
        let scan = NSMenu(title: "Scan")
        for (title, action, key) in [
            ("Start Scanning", #selector(startScan), "s"),
            ("Stop Scanning", #selector(stopScan), "d"),
            ("New Match", #selector(newMatch), "n"),
            ("Read Screenshot…", #selector(openScreenshot), "")
        ] {
            let item = scan.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = [.control, .shift]
            item.target = self
        }
        scanItem.submenu = scan
        menuBar.addItem(scanItem)
        NSApp.mainMenu = menuBar
    }

    @objc private func startScan() { dashboard.start() }
    @objc private func stopScan() { dashboard.stop() }
    @objc private func newMatch() { dashboard.newMatch() }
    @objc private func openScreenshot() { dashboard.loadImage() }
}

@main
private enum WordRelay {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = WordRelayDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
