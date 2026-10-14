import AppKit
import SiriusCore

// The status item and its menu. Everything else the app shows is a panel.
// Option-click adds the Debug items: the toast transition cases, the
// dictation pill's previews, the onboarding at each step and slow motion.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let queue: CommandQueue
    // Opens the onboarding at a step.
    private let openOnboarding: (OnboardingStep) -> Void
    // Opens the composer, and its shortcut now, for the Compose item: the
    // composer is reachable even when its shortcut is not (a tester,
    // 2026.10.12).
    private let openComposer: () -> Void
    private let composeShortcut: () -> KeyCombo
    private var debugItems: [NSMenuItem] = []
    private(set) var composeItem: NSMenuItem?

    init(queue: CommandQueue, openOnboarding: @escaping (OnboardingStep) -> Void,
         openComposer: @escaping () -> Void = {}, composeShortcut: @escaping () -> KeyCombo = { .compose }) {
        self.queue = queue
        self.openOnboarding = openOnboarding
        self.openComposer = openComposer
        self.composeShortcut = composeShortcut
    }

    // Compose, above Settings…, with the current shortcut as its hint.
    func makeComposeItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Compose", action: #selector(compose(_:)), keyEquivalent: "") // TODO(andrew): copy
        item.target = self
        updateComposeItem(item)
        return item
    }

    func updateComposeItem(_ item: NSMenuItem) {
        if let key = KeyComboText.menuKey(composeShortcut()) {
            item.keyEquivalent = key.key
            item.keyEquivalentModifierMask = key.modifiers
        } else {
            item.keyEquivalent = ""
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Sparkle's scheduled checks, before the menu, which
        // shows "Check for Updates…" only once they run.
        Updater.start()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // TODO(andrew): the menu-bar icon.
        item.button?.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Sirius")
        let menu = NSMenu()
        menu.delegate = self
        debugItems = makeDebugItems()
        for debug in debugItems { menu.addItem(debug) }
        let compose = makeComposeItem()
        composeItem = compose
        menu.addItem(compose)
        let setup = NSMenuItem(title: "Settings…", action: #selector(showSetup(_:)), keyEquivalent: ",")
        setup.target = self
        menu.addItem(setup)
        // Below Settings…, as in Parrot's menu.
        let updates = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        updates.target = self
        updates.isHidden = !Updater.isRunning
        menu.addItem(updates)
        menu.addItem(.separator())
        // Its own selector: macOS 26 gives items whose action is
        // `terminate(_:)` an xmark icon.
        let quit = NSMenuItem(title: "Quit Sirius", action: #selector(quit(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let option = NSEvent.modifierFlags.contains(.option)
        for debug in debugItems { debug.isHidden = !option }
        if let composeItem { updateComposeItem(composeItem) }
        debugItems.first { $0.action == #selector(toggleSlow(_:)) }?.state = SpatialMotion.timeScale > 1 ? .on : .off
    }

    private func makeDebugItems() -> [NSMenuItem] {
        let cases = NSMenu()
        for (index, sequence) in DevDemo.sequences.enumerated() {
            let item = NSMenuItem(title: "\(index + 1). \(sequence.name)", action: #selector(playCase(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index + 1
            cases.addItem(item)
        }
        let casesItem = NSMenuItem(title: "Toast Cases", action: nil, keyEquivalent: "")
        casesItem.submenu = cases
        let pill = NSMenuItem(title: "Dictation Pill", action: #selector(previewPill(_:)), keyEquivalent: "")
        pill.target = self
        let download = NSMenuItem(title: "Dictation Pill: Download", action: #selector(previewDownload(_:)), keyEquivalent: "")
        download.target = self
        let onboarding = NSMenu()
        for step in OnboardingStep.allCases {
            let item = NSMenuItem(title: Self.debugName(step), action: #selector(showOnboarding(_:)), keyEquivalent: "")
            item.target = self
            item.tag = step.rawValue
            onboarding.addItem(item)
        }
        let onboardingItem = NSMenuItem(title: "Onboarding", action: nil, keyEquivalent: "")
        onboardingItem.submenu = onboarding
        let slow = NSMenuItem(title: "Slow Motion (10×)", action: #selector(toggleSlow(_:)), keyEquivalent: "")
        slow.target = self
        return [casesItem, pill, download, onboardingItem, slow, .separator()]
    }

    private static func debugName(_ step: OnboardingStep) -> String {
        switch step {
        case .welcome: "Welcome"
        case .agents: "Agents"
        case .permissions: "Permissions"
        case .done: "Done"
        }
    }

    @objc private func playCase(_ item: NSMenuItem) {
        DevDemo.play(item.tag, queue: queue)
    }

    @objc private func previewPill(_ item: NSMenuItem) {
        DictationPillDemo.dictation()
    }

    @objc private func previewDownload(_ item: NSMenuItem) {
        DictationPillDemo.download()
    }

    // The onboarding at its agents step.
    @objc private func showSetup(_ item: NSMenuItem) {
        openOnboarding(.agents)
    }

    // Once the menu has closed, so the composer takes the keyboard.
    @objc func compose(_ item: NSMenuItem?) {
        SiriusLog.composer.info("composer: opened from the menu")
        DispatchQueue.main.async { [openComposer] in openComposer() }
    }

    @objc private func showOnboarding(_ item: NSMenuItem) {
        guard let step = OnboardingStep(rawValue: item.tag) else { return }
        openOnboarding(step)
    }

    @objc private func toggleSlow(_ item: NSMenuItem) {
        SpatialMotion.timeScale = SpatialMotion.timeScale > 1 ? 1 : 10
    }

    @objc private func checkForUpdates(_ item: NSMenuItem) {
        Updater.checkForUpdates()
    }

    @objc private func quit(_ item: NSMenuItem) {
        NSApp.terminate(nil)
    }
}
