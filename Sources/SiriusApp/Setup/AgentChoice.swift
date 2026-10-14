import AppKit
import SiriusAdapters
import SiriusCore
import SiriusProtocol

// One harness in the onboarding's agents step: whether its CLI was found,
// whether it is on, and its folder, never the home folder. Moved from
// SetupWindow's SetupRow when the onboarding replaced it; the rules are
// setup's.
@MainActor
final class AgentChoice: ObservableObject, Identifiable {
    let harness: AgentRegistration.Harness
    nonisolated var id: String { harness.rawValue }

    // Nil while the shell lookup runs; then found or not.
    @Published private(set) var executable: String?
    @Published private(set) var looking = true
    @Published var isOn: Bool
    @Published private(set) var root: String?

    private let current: AgentRegistration?
    private let detector: AgentDetector

    init(harness: AgentRegistration.Harness, current: AgentRegistration?, detector: AgentDetector) {
        self.harness = harness
        self.current = current
        self.detector = detector
        root = current?.root
        isOn = current != nil
    }

    static func name(_ harness: AgentRegistration.Harness) -> String {
        switch harness {
        case .claudeCode: "Claude"
        case .codex: "Codex"
        }
    }

    // The registry folder and id, fixed after setup.
    static func id(_ harness: AgentRegistration.Harness) -> String {
        switch harness {
        case .claudeCode: "claude"
        case .codex: "codex"
        }
    }

    var name: String { Self.name(harness) }

    // The shell lookup can take a few seconds; it runs off the main thread.
    func detect() {
        let detector = detector
        let harness = harness
        Task.detached {
            let path = detector.find(harness)
            await MainActor.run { self.setExecutable(path) }
        }
    }

    // A debug path (OnboardingSnapshots): found at `path`, no lookup.
    func simulateFound(_ path: String) {
        setExecutable(path)
    }

    private func setExecutable(_ path: String?) {
        looking = false
        // An existing registration's own executable wins if it still runs.
        if let registered = current?.executable, FileManager.default.isExecutableFile(atPath: registered) {
            executable = registered
        } else {
            executable = path
        }
        if executable != nil {
            if current == nil, root == nil { isOn = true }
        } else {
            isOn = false
        }
    }

    // What onboarding writes for this harness, or nil when it is off or
    // incomplete. Keeps an existing registration's name, voice, model and
    // effort.
    var registration: AgentRegistration? {
        guard isOn, let executable, let root else { return nil }
        var registration = current ?? AgentRegistration(agent: Self.id(harness), name: Self.name(harness),
                                                        harness: harness, executable: executable, root: root)
        registration.executable = executable
        registration.root = root
        return registration
    }

    // The folder panel as a sheet on `window`; a home folder or the disk's
    // root is refused with an alert.
    func chooseFolder(in window: NSWindow) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose" // TODO(copy): copy
        panel.message = "The folder \(name) works in" // TODO(copy): copy
        if let root { panel.directoryURL = URL(fileURLWithPath: root, isDirectory: true) }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            guard self.detector.isAcceptableRoot(url.path) else {
                let alert = NSAlert()
                alert.messageText = "Choose a narrower folder" // TODO(copy): copy
                // TODO(copy): copy
                alert.informativeText = "An agent can't work in your home folder or the whole disk. Pick a project or workspace folder."
                alert.beginSheetModal(for: window)
                return
            }
            self.root = url.path
            self.isOn = true
        }
    }
}
