import AppKit
import Combine
import ParrotCore
import SiriusAdapters
import SiriusCore
import SiriusProtocol
import SwiftUI

// The Settings window, opened from the menu's Settings… (⌘,). Parrot's
// pills and rows (Pill.swift) in a 700 × 560 window with a 200 pt sidebar
// of General, Permissions, Agents, Context and Dictation. Agents opens on a list of the
// agents; a click puts one in focus under a bare "‹".
//
// It shows only what Sirius stores: the two shortcuts (Shortcuts, through
// ShortcutsModel), the grants (GrantsModel, read live), each agent's
// agent.json (workspace, fast mode, model, effort) and the dictation model
// (UserDefaults' dictation.model, chosen here and applied at once). Each
// change writes straight through: an agent's agent.json is written at once
// and the host reloads it, restarting that agent, as Parrot's window writes
// its settings.json.
//
// One instance: opening it again brings the same window forward. Esc steps
// back from an agent to the list, and otherwise closes, as ⌘W does.
@MainActor
final class SettingsWindow {
    static let size = NSSize(width: 700, height: 560)
    static let maxSize = NSSize(width: 1000, height: 1100)

    private let registry: AgentRegistry
    private let detector: AgentDetector
    private let shortcuts: ShortcutsModel
    private let onSave: () -> Void
    // Told the dictation model chosen in this window, to apply it at once.
    private let onDictationModel: (String) -> Void
    private var window: NSWindow?
    private var model: SettingsModel?
    private lazy var delegate = Delegate(owner: self)

    init(registry: AgentRegistry, shortcuts: ShortcutsModel, detector: AgentDetector = AgentDetector(),
         onSave: @escaping () -> Void = {}, onDictationModel: @escaping (String) -> Void = { _ in }) {
        self.registry = registry
        self.shortcuts = shortcuts
        self.detector = detector
        self.onSave = onSave
        self.onDictationModel = onDictationModel
    }

    func show() {
        if let window {
            bringForward(window)
            return
        }
        let existing = registry.loadAll().agents.map(\.registration)
        let agents = AgentChoice.choices(existing: existing, detector: detector)
        let registry = registry
        let model = SettingsModel(agents: agents, shortcuts: shortcuts, dictation: DictationModel().model,
                                  write: { try registry.register($0) }, onSave: onSave,
                                  onDictationModel: onDictationModel)
        self.model = model
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        // Always the app's dark sky, whatever the system's appearance, as
        // the onboarding; text and controls follow.
        window.appearance = NSAppearance(named: .darkAqua)
        // Never smaller than the size the panes were laid out for; larger
        // gives the rows more room and Context's list more height.
        window.contentMinSize = Self.size
        window.contentMaxSize = Self.maxSize
        window.title = "Sirius Settings" // TODO(copy): copy
        // The sidebar says it; the title still names the window in Mission
        // Control and the window switcher.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        let hosting = NSHostingView(rootView: SettingsView(model: model))
        hosting.sizingOptions = []
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.delegate = delegate
        window.center()
        model.window = window
        model.close = { [weak window] in window?.performClose(nil) }
        self.window = window
        model.grants.start()
        for agent in agents { agent.detect() }
        bringForward(window)
    }

    private func bringForward(_ window: NSWindow) {
        // An accessory app is never active on its own; without this the
        // window opens behind the frontmost app.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    // Closing drops the model, so the next Settings… reads agent.json again.
    fileprivate func closed() {
        shortcuts.cancelRecording()
        model?.grants.stop()
        model = nil
        window = nil
    }

    private final class Delegate: NSObject, NSWindowDelegate {
        private weak var owner: SettingsWindow?

        init(owner: SettingsWindow) { self.owner = owner }

        func windowWillClose(_ notification: Notification) {
            MainActor.assumeIsolated { owner?.closed() }
        }
    }
}

// The sidebar's sections, in its order.
enum SettingsSection: String, CaseIterable, Hashable {
    case general, permissions, agents, context, dictation

    var title: String {
        switch self {
        case .general: "General" // TODO(copy): copy
        case .permissions: "Permissions" // TODO(copy): copy
        case .agents: "Agents" // TODO(copy): copy
        case .context: "Context" // TODO(copy): copy
        case .dictation: "Dictation" // TODO(copy): copy
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .permissions: "hand.raised"
        case .agents: "person.2"
        case .context: "text.viewfinder"
        case .dictation: "mic"
        }
    }
}

// What the window shows and what it changes.
@MainActor
final class SettingsModel: ObservableObject {
    @Published var section: SettingsSection
    // The agent in focus under Agents; nil shows the list.
    @Published var focused: AgentRegistration.Harness?
    let agents: [AgentChoice]
    let shortcuts: ShortcutsModel
    let grants = GrantsModel()
    let context: ContextSettings
    @Published private(set) var dictation: TranscriptionModel
    // The models the Dictation picker offers, in the registry's order
    // (DictationModel.catalog), sizes and all.
    let dictationOptions: [TranscriptionModel]
    weak var window: NSWindow?
    var close: () -> Void = {}

    // Writes one agent.json (AgentRegistry.register in the app; a stand-in
    // in the tests), then tells the host to reload.
    private let write: (AgentRegistration) throws -> Void
    // The folders a harness already trusts, read from its own files; never
    // written by Sirius.
    let trusted: @Sendable (AgentRegistration.Harness) -> [String]
    private let onSave: () -> Void
    private let defaults: UserDefaults
    // Told the model chosen in Settings → Dictation, to apply it at once
    // (DictationService.applyModel in the app).
    private let onDictationModel: (String) -> Void
    private var forwarding: [AnyCancellable] = []

    init(agents: [AgentChoice], shortcuts: ShortcutsModel, dictation: TranscriptionModel,
         section: SettingsSection = .general, context: ContextSettings? = nil,
         trusted: @escaping @Sendable (AgentRegistration.Harness) -> [String] = { TrustedFolders().folders(for: $0) },
         defaults: UserDefaults = .standard,
         write: @escaping (AgentRegistration) throws -> Void, onSave: @escaping () -> Void = {},
         onDictationModel: @escaping (String) -> Void = { _ in }) {
        self.trusted = trusted
        self.agents = agents
        self.shortcuts = shortcuts
        self.dictation = dictation
        self.dictationOptions = DictationModel.catalog
        self.section = section
        let context = context ?? ContextSettings()
        self.context = context
        self.write = write
        self.defaults = defaults
        self.onSave = onSave
        self.onDictationModel = onDictationModel
        let children = agents.map(\.objectWillChange) + [grants.objectWillChange, shortcuts.objectWillChange, context.objectWillChange]
        forwarding = children.map { $0.sink { [weak self] _ in self?.objectWillChange.send() } }
    }

    // A sidebar click: the section, at its top.
    func select(_ section: SettingsSection) {
        self.section = section
        focused = nil
    }

    func focus(_ harness: AgentRegistration.Harness) {
        section = .agents
        focused = harness
    }

    // Esc and "‹": from an agent back to the list, true; otherwise false,
    // and the window closes.
    @discardableResult
    func back() -> Bool {
        guard focused != nil else { return false }
        focused = nil
        return true
    }

    func agent(_ harness: AgentRegistration.Harness) -> AgentChoice? {
        agents.first { $0.harness == harness }
    }

    // Writes the agent's agent.json if it differs from what is registered,
    // then reloads the host. An agent with no workspace yet writes nothing;
    // its choices wait for one. Returns whether it wrote.
    @discardableResult
    func save(_ agent: AgentChoice) -> Bool {
        guard let registration = agent.registration, registration != agent.current else { return false }
        do {
            try write(registration)
        } catch {
            SiriusLog.onboarding.error("settings: couldn't save \(registration.agent): \(error)")
            let alert = NSAlert()
            alert.messageText = "Couldn't save \(registration.name)" // TODO(copy): copy
            alert.informativeText = "\(error)"
            if let window { alert.beginSheetModal(for: window) }
            return false
        }
        SiriusLog.onboarding.info("settings: saved \(registration.agent)")
        agent.saved(registration)
        onSave()
        return true
    }

    // The app's version, from its bundle; "dev" under `swift run`.
    var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    // The dictation model's line: its speed, languages and size, and that
    // Parrot shares the weights (DictationModel).
    var dictationNote: String {
        Self.dictationNote(dictation)
    }

    static func dictationNote(_ model: TranscriptionModel) -> String {
        let languages = model.languages == ["en"] ? "English only" : "Multilingual" // TODO(copy): copy
        return "\(languages) · \(model.sizeMB) MB · shared with Parrot" // TODO(copy): copy
    }

    // A model's line in the Dictation picker.
    static func dictationOptionLabel(_ model: TranscriptionModel) -> String {
        let languages = model.languages == ["en"] ? "English only" : "Multilingual"
        return "\(model.displayName) · \(languages) · \(model.sizeMB) MB" // TODO(copy): copy
    }

    // The Dictation picker's choice, written through to UserDefaults'
    // dictation.model (DictationModel reads it at each load) and told to
    // the app, which applies it at once. Nothing is written for the model
    // already in use.
    func selectDictation(model: TranscriptionModel) {
        guard model.id != dictation.id else { return }
        objectWillChange.send()
        dictation = model
        defaults.set(model.id, forKey: DictationModel.defaultsKey)
        SiriusLog.onboarding.info("settings: \(DictationModel.defaultsKey) \(model.id)")
        onDictationModel(model.id)
    }
}

extension AgentChoice {
    // One choice per harness, each with what agent.json holds for it, and
    // the folder `trusted` offers a new one (the onboarding's; none in
    // Settings, where a new agent's workspace is chosen).
    static func choices(existing: [AgentRegistration], detector: AgentDetector,
                        trusted: (AgentRegistration.Harness) -> String? = { _ in nil }) -> [AgentChoice] {
        AgentRegistration.Harness.allCases.map { harness in
            let current = existing.first { $0.harness == harness }
            return AgentChoice(harness: harness, current: current, detector: detector,
                               trusted: current == nil ? trusted(harness) : nil)
        }
    }
}
