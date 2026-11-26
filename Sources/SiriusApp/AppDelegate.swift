import AppKit
import SiriusAdapters
import SiriusCore

// The status item and its menu. Everything else the app shows is a panel.
// Option-click adds the Debug items: the toast transition cases, the
// dictation pill's previews, the onboarding and slow motion.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let queue: CommandQueue
    // Opens the onboarding; with true, at its agents. The debug menu's
    // Onboarding item.
    private let openOnboarding: (_ agents: Bool) -> Void
    // "Open manual" with a small raised ↗, as a superscript, in the menu's
    // own font.
    /// The silver star at 19 pt, as a template image so macOS tints it for a light, dark or highlighted bar,
    /// as Paper does with its enso. Both scales are in `images/`; nil when the bundle lacks them.
    static var menuBarImage: NSImage? {
        let image = NSImage(size: NSSize(width: 19, height: 19))
        for name in ["menubar-star", "menubar-star@2x"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "images"),
                  let rep = NSBitmapImageRep(data: (try? Data(contentsOf: url)) ?? Data()) else { continue }
            rep.size = image.size
            image.addRepresentation(rep)
        }
        guard !image.representations.isEmpty else { return nil }
        image.isTemplate = true
        image.accessibilityDescription = "Sirius"
        return image
    }

    static var manualTitle: NSAttributedString {
        let font = NSFont.menuFont(ofSize: 0)
        // A full space before the arrow, at the title's size, so it does
        // not touch the word.
        let title = NSMutableAttributedString(string: "Open manual ", attributes: [.font: font]) // TODO(copy): copy
        title.append(NSAttributedString(string: "\u{2197}\u{FE0E}", attributes: [
            .font: NSFont.menuFont(ofSize: font.pointSize * 0.7),
            .baselineOffset: font.pointSize * 0.35,
        ]))
        return title
    }

    // Opens the Settings window, for Settings….
    private let openSettings: () -> Void
    // Opens the composer, and its shortcut now, for the Compose item: the
    // composer is reachable even when its shortcut is not (a tester,
    // 2026.10.12).
    private let openComposer: () -> Void
    private let composeShortcut: () -> KeyCombo
    // Whether any agent has a last response to show again, and what shows
    // it, for the Last response item.
    private let lastResponse: () -> Bool
    private let showLast: () -> Void
    private var debugItems: [NSMenuItem] = []
    private(set) var composeItem: NSMenuItem?
    private(set) var lastItem: NSMenuItem?

    init(queue: CommandQueue, openOnboarding: @escaping (_ agents: Bool) -> Void,
         openSettings: @escaping () -> Void = {},
         openComposer: @escaping () -> Void = {}, composeShortcut: @escaping () -> KeyCombo = { .compose },
         lastResponse: @escaping () -> Bool = { false },
         showLast: @escaping () -> Void = {}) {
        self.queue = queue
        self.openOnboarding = openOnboarding
        self.openSettings = openSettings
        self.openComposer = openComposer
        self.composeShortcut = composeShortcut
        self.lastResponse = lastResponse
        self.showLast = showLast
    }

    // Compose, above Settings…, with the current shortcut as its hint.
    func makeComposeItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Compose", action: #selector(compose(_:)), keyEquivalent: "") // TODO(copy): copy
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
        // shows "Check for updates…" only once they run.
        Updater.start()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.menuBarImage
            ?? SiriusMark.template()
        let menu = NSMenu()
        menu.delegate = self
        debugItems = makeDebugItems()
        for debug in debugItems { menu.addItem(debug) }
        let compose = makeComposeItem()
        composeItem = compose
        menu.addItem(compose)
        // The agent's last response, on demand: a toast that has already
        // left can be asked for again.
        let last = NSMenuItem(title: "Last response", action: #selector(showLastResponse(_:)), keyEquivalent: "") // TODO(copy): copy
        last.target = self
        lastItem = last
        menu.addItem(last)
        let setup = NSMenuItem(title: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        setup.target = self
        menu.addItem(setup)
        let updates = NSMenuItem(title: "Check for updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        updates.target = self
        updates.isHidden = !Updater.isRunning
        menu.addItem(.separator())
        // The manual's PDF, first in the bottom group, so it can be read when no agent
        // answers. Absent from a bare `swift build`, which has no bundle to
        // hold it.
        let manual = NSMenuItem(title: "Open manual \u{2197}\u{FE0E}", action: #selector(showManual(_:)), keyEquivalent: "")
        manual.attributedTitle = Self.manualTitle
        manual.target = self
        manual.isHidden = !FileManager.default.fileExists(atPath: Self.manualURL.path)
        menu.addItem(manual)
        // In the bottom group, between the manual and Quit.
        menu.addItem(updates)
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
        lastItem?.isEnabled = lastResponse()
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
        let onboardingItem = NSMenuItem(title: "Onboarding", action: #selector(showOnboarding(_:)), keyEquivalent: "")
        onboardingItem.target = self
        let slow = NSMenuItem(title: "Slow Motion (10×)", action: #selector(toggleSlow(_:)), keyEquivalent: "")
        slow.target = self
        return [casesItem, pill, download, onboardingItem, slow, .separator()]
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

    // The Settings window, not the onboarding.
    @objc func showSettings(_ item: NSMenuItem?) {
        openSettings()
    }

    // Once the menu has closed, so the composer takes the keyboard.
    @objc func compose(_ item: NSMenuItem?) {
        SiriusLog.composer.info("composer: opened from the menu")
        DispatchQueue.main.async { [openComposer] in openComposer() }
    }

    // The agent's last response again, under its own mark.
    @objc private func showLastResponse(_ item: NSMenuItem) {
        showLast()
    }

    @objc private func showOnboarding(_ item: NSMenuItem) {
        openOnboarding(false)
    }

    @objc private func toggleSlow(_ item: NSMenuItem) {
        SpatialMotion.timeScale = SpatialMotion.timeScale > 1 ? 1 : 10
    }

    static var manualURL: URL {
        AgentHost.templatesDirectory()
            .appendingPathComponent(Instructions.manual, isDirectory: true)
            .appendingPathComponent("Sirius Manual.pdf")
    }

    @objc private func showManual(_ item: NSMenuItem) {
        NSWorkspace.shared.open(Self.manualURL)
    }

    @objc private func checkForUpdates(_ item: NSMenuItem) {
        Updater.checkForUpdates()
    }

    @objc private func quit(_ item: NSMenuItem) {
        NSApp.terminate(nil)
    }
}
