import AppKit
import SiriusCore

// The last page's two shortcuts, rebindable in place (the spec's
// "Rebindable shortcuts"). Compose is recorded: a click on it sets the
// current shortcut aside and shows "Press new shortcut…"; the next key with
// ⌘, ⌃ or ⌥ (or an F-key) is bound unless macOS or another app has it, in
// which case "Taken by macOS" or "Taken by another app" shows in place and
// the old one stays. Esc cancels. Hold to talk is chosen from a short list,
// the keys that can be held (HoldKey). Both persist (Shortcuts), through
// the composer (ComposerController.rebind) and dictation
// (DictationService.setHoldKey).
@MainActor
final class ShortcutsModel: ObservableObject {
    enum State: Equatable {
        case idle
        // Waiting for a key; `hint` after one without a modifier.
        case recording(hint: String?)
        // A combo that could not be had, shown in place for a moment.
        case refused(String)
    }

    @Published private(set) var compose: KeyCombo
    @Published private(set) var holdKey: HoldKey
    @Published private(set) var state: State = .idle

    // How long a refusal shows before the old shortcut comes back.
    static let refusalShown: TimeInterval = 2

    private let rebind: (KeyCombo) -> ComposerController.Rebind
    private let suspend: () -> Void
    private let resume: () -> Void
    private let chooseHoldKey: (HoldKey) -> Void
    private var monitor: Any?
    // What ends a recording besides Esc: the window closing or losing the
    // keyboard, or Sirius losing it.
    private var endObservers: [NSObjectProtocol] = []
    // The window the recording is in; only its keys are recorded.
    private weak var recordingWindow: NSWindow?
    private var refusalTimer: Timer?

    init(compose: KeyCombo, holdKey: HoldKey,
         rebind: @escaping (KeyCombo) -> ComposerController.Rebind = { _ in .bound },
         suspend: @escaping () -> Void = {}, resume: @escaping () -> Void = {},
         chooseHoldKey: @escaping (HoldKey) -> Void = { _ in }) {
        self.compose = compose
        self.holdKey = holdKey
        self.rebind = rebind
        self.suspend = suspend
        self.resume = resume
        self.chooseHoldKey = chooseHoldKey
    }

    static func live(composer: ComposerController, dictation: DictationService) -> ShortcutsModel {
        ShortcutsModel(compose: composer.shortcut, holdKey: dictation.holdKey,
                       rebind: { [weak composer] in composer?.rebind($0) ?? .takenByApp },
                       suspend: { [weak composer] in composer?.suspendShortcut() },
                       resume: { [weak composer] in composer?.resumeShortcut() },
                       chooseHoldKey: { [weak dictation] in dictation?.setHoldKey($0) })
    }

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    // MARK: Compose

    // Records the next key pressed in `window`. Until it ends the shortcut
    // is set aside, so every way out must resume it: Esc, a refusal, a
    // binding, and the window closing or losing the keyboard (Skip, the
    // dissolve as the composer opens, ⌘W, a click in another app). The page's
    // onDisappear never fires as a window closes (tested 2026.10.12), and
    // the shortcut stayed unregistered until relaunch (a tester, 2026.10.12:
    // "⌘⇧J never opens the composer").
    func startRecording(in window: NSWindow?) {
        guard !isRecording else { return }
        refusalTimer?.invalidate()
        suspend()
        state = .recording(hint: nil)
        recordingWindow = window
        SiriusLog.hotkey.info("compose shortcut: recording a new one; \(KeyComboText.string(compose)) set aside")
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let taken = MainActor.assumeIsolated { self?.take(event) ?? false }
            return taken ? nil : event
        }
        let center = NotificationCenter.default
        let end: @Sendable (Notification) -> Void = { [weak self] note in
            MainActor.assumeIsolated {
                SiriusLog.hotkey.info("compose shortcut: recording ended by \(note.name.rawValue)")
                self?.cancelRecording()
            }
        }
        if let window {
            endObservers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                   queue: .main, using: end))
            endObservers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window,
                                                   queue: .main, using: end))
        }
        endObservers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                                               queue: .main, using: end))
    }

    // Esc, a click elsewhere, or the page going: the old shortcut stays.
    func cancelRecording() {
        guard isRecording else { return }
        stopMonitor()
        resume()
        state = .idle
    }

    // The recording's key monitor: a key in the recording window is taken;
    // any other passes untouched. It once took every key Sirius was sent,
    // so a recording left running swallowed the composer's typing.
    func take(_ event: NSEvent) -> Bool {
        guard isRecording else { return false }
        if let recordingWindow, event.windowNumber != recordingWindow.windowNumber { return false }
        recorded(event)
        return true
    }

    private func recorded(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53, flags.intersection([.command, .control, .option, .shift]).isEmpty {
            return cancelRecording()
        }
        let combo = KeyCombo(keyCode: UInt32(event.keyCode), modifiers: Self.carbonModifiers(flags))
        switch rebind(combo) {
        case .bound:
            stopMonitor()
            compose = combo
            state = .idle
        case .needsModifier:
            state = .recording(hint: "Add ⌘, ⌃ or ⌥") // TODO(andrew): copy
        case .takenByMacOS:
            refuse("Taken by macOS")
        case .takenByApp:
            refuse("Taken by another app")
        }
    }

    private func refuse(_ text: String) {
        stopMonitor()
        resume()
        state = .refused(text)
        refusalTimer?.invalidate()
        refusalTimer = Timer.scheduledTimer(withTimeInterval: Self.refusalShown, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, case .refused = self.state else { return }
                self.state = .idle
            }
        }
    }

    private func stopMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        for observer in endObservers { NotificationCenter.default.removeObserver(observer) }
        endObservers = []
        recordingWindow = nil
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= KeyCombo.command }
        if flags.contains(.shift) { modifiers |= KeyCombo.shift }
        if flags.contains(.option) { modifiers |= KeyCombo.option }
        if flags.contains(.control) { modifiers |= KeyCombo.control }
        return modifiers
    }

    // MARK: Hold to talk

    func choose(_ key: HoldKey) {
        guard key != holdKey else { return }
        holdKey = key
        chooseHoldKey(key)
    }

    // The list, as a menu at the pointer in `view`.
    func showHoldKeyMenu(in view: NSView) {
        let menu = NSMenu()
        for key in HoldKey.allCases {
            let item = NSMenuItem(title: key.menuTitle, action: #selector(MenuTarget.chosen(_:)), keyEquivalent: "")
            item.target = MenuTarget.shared
            item.representedObject = key.rawValue
            item.state = key == holdKey ? .on : .off
            menu.addItem(item)
        }
        MenuTarget.shared.choose = { [weak self] raw in HoldKey(rawValue: raw).map { self?.choose($0) } }
        guard let window = view.window else { return }
        let point = view.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        menu.popUp(positioning: menu.items.first { $0.state == .on }, at: point, in: view)
    }

    // A debug path (OnboardingSnapshots): shows `state` without recording.
    func simulate(_ state: State) {
        self.state = state
    }

    private final class MenuTarget: NSObject {
        static let shared = MenuTarget()
        var choose: (String) -> Void = { _ in }

        @objc func chosen(_ item: NSMenuItem) {
            if let raw = item.representedObject as? String { choose(raw) }
        }
    }
}
