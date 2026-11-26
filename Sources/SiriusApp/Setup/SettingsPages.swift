import AppKit
import SiriusAdapters
import SiriusCore
import SiriusProtocol
import SwiftUI

// The Settings window's page: the sidebar on the left, the section on the
// right, laid out as the approved mock (heap/0245/20261102-settings-agents-list.swift).
struct SettingsView: View {
    static let sidebarWidth: CGFloat = 200

    @ObservedObject var model: SettingsModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(model: model)
                .frame(width: Self.sidebarWidth)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Color.primary.opacity(0.03))
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                content
                    .id(model.focused.map { "agent-\($0.rawValue)" } ?? model.section.rawValue)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 32)
            .padding(.top, 56)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: SettingsWindow.size.width, maxWidth: .infinity,
               minHeight: SettingsWindow.size.height, maxHeight: .infinity)
        .background {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                // The onboarding's sky (NightSky), faint behind the panes so
                // the controls read as before; off under Reduce Transparency.
                if !reduceTransparency {
                    NightSky().opacity(Self.skyOpacity(colorScheme))
                }
            }
        }
        // Under the transparent title bar, as the mock: the insets above
        // count from the window's top edge.
        .ignoresSafeArea()
        // ⌘W closes: an accessory app has no menu bar of its own to carry
        // Close. Behind the page, so it takes no row.
        .background {
            Button("Close") { model.close() } // TODO(copy): copy
                .keyboardShortcut("w", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .onExitCommand { if !model.back() { model.close() } }
    }

    // The sky's strength: a quiet wash in dark mode, a bare tint in light.
    static func skyOpacity(_ scheme: ColorScheme) -> Double {
        scheme == .dark ? 0.45 : 0.06
    }

    @ViewBuilder
    private var content: some View {
        switch model.section {
        case .general:
            // Keys, then how long toasts stay: what is about Sirius itself
            // and no one agent.
            VStack(alignment: .leading, spacing: 26) {
                KeysPane(shortcuts: model.shortcuts, window: { [weak model] in model?.window })
                ToastsGroup()
            }
        case .permissions: PermissionsPane(grants: model.grants)
        case .agents:
            if let harness = model.focused, let agent = model.agent(harness) {
                AgentDetail(agent: agent, model: model)
            } else {
                AgentsPane(model: model)
            }
        case .context: ContextPane(context: model.context)
        case .dictation: DictationPane(model: model)
        }
    }
}

// The sparkle, the name and the version, then a row per section, the
// selected one in Parrot's light-fill capsule.
private struct SettingsSidebar: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                Group {
                    if let star = SiriusMark.silver {
                        Image(nsImage: star).resizable().aspectRatio(contentMode: .fit).frame(width: 44, height: 44)
                    } else {
                        Image(systemName: "sparkle").font(.system(size: 30, weight: .light))
                    }
                }
                .frame(height: 44)
                Text("Sirius").font(.headline)
                Text("Version \(model.version)") // TODO(copy): copy
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 48)
            .padding(.bottom, 24)
            VStack(spacing: 2) {
                ForEach(SettingsSection.allCases, id: \.self) { section in
                    SidebarRow(section: section, selected: section == model.section) {
                        model.select(section)
                    }
                }
            }
            .padding(.horizontal, 12)
        }
    }
}

private struct SidebarRow: View {
    let section: SettingsSection
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: section.symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                Text(section.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color.primary.opacity(selected ? 0.08 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// Hold to talk from its list, paste at the cursor as it follows from it,
// and Compose, recorded in place (ShortcutsModel).
private struct KeysPane: View {
    @ObservedObject var shortcuts: ShortcutsModel
    let window: () -> NSWindow?

    var body: some View {
        SettingsGroup("Keys") { // TODO(copy): copy
            PillRow("Hold to talk") { // TODO(copy): copy
                PillMenu(title: shortcuts.holdKey.menuTitle) {
                    ForEach(HoldKey.allCases, id: \.self) { key in
                        Button(key.menuTitle) { shortcuts.choose(key) }
                    }
                }
            }
            PillRow("Paste at cursor") { // TODO(copy): copy
                PillMenu(title: shortcuts.holdKey.pasteGlyph(shortcuts.pasteModifier)) {
                    ForEach(PasteModifier.options(for: shortcuts.holdKey), id: \.self) { paste in
                        Button(shortcuts.holdKey.pasteGlyph(paste)) { shortcuts.choose(paste: paste) }
                    }
                }
            }
            PillRow("Compose") { // TODO(copy): copy
                Button(shortcuts.composeText) {
                    shortcuts.isRecording ? shortcuts.cancelRecording() : shortcuts.startRecording(in: window())
                }
                .buttonStyle(.pill)
                .onDisappear { shortcuts.cancelRecording() }
            }
        }
    }
}

// Microphone and Accessibility, each Allowed or with its Allow pill, which
// prompts or opens the pane (Grants.allowSteps); live as they change.
private struct PermissionsPane: View {
    @ObservedObject var grants: GrantsModel

    var body: some View {
        SettingsGroup("Permissions") { // TODO(copy): copy
            PillRow("Microphone") { permission(.microphone) } // TODO(copy): copy
            PillRow("Accessibility") { permission(.accessibility) } // TODO(copy): copy
            if grants.parrotRunning {
                Text("Quit Parrot so fn isn't handled twice.") // TODO(copy): copy
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func permission(_ grant: Grant) -> some View {
        if grants.isGranted(grant) {
            Label("Allowed", systemImage: "checkmark.circle.fill") // TODO(copy): copy
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.multicolor)
                .padding(.vertical, 6)
        } else {
            Button("Allow") { grants.allow(grant) } // TODO(copy): copy
                .buttonStyle(.primaryPill)
                .disabled(grants.steps(grant).isEmpty)
        }
    }
}

// Every agent: its mark, name, workspace, model and effort, whether it is
// registered, and a chevron; a click puts it in focus.
private struct AgentsPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        SettingsGroup("Agents") { // TODO(copy): copy
            ForEach(model.agents) { agent in
                SettingsAgentRow(agent: agent) { model.focus(agent.harness) }
            }
        }
    }
}

// How long a toast stays before it leaves by itself (ToastStay). Alerts
// stay until dismissed whatever this says.
private struct ToastsGroup: View {
    @AppStorage(ToastStay.key) private var seconds = ToastStay.defaultSeconds

    var body: some View {
        SettingsGroup("Toasts") { // TODO(copy): copy
            PillRow("Duration") { // TODO(copy): copy
                PillMenu(title: label(ToastStay.choices.contains(seconds) ? seconds : ToastStay.defaultSeconds)) {
                    ForEach(ToastStay.choices, id: \.self) { choice in
                        Button(label(choice)) { seconds = choice }
                    }
                }
            }
        }
    }

    private func label(_ value: TimeInterval) -> String { "\(Int(value)) s" }
}

private struct SettingsAgentRow: View {
    @ObservedObject var agent: AgentChoice
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                AgentMark(harness: agent.harness, size: 22, ink: .primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.name)
                    Text(agent.settingsSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Text(agent.isRunning ? "On" : "Off") // TODO(copy): copy
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            // A plain row, as the Context page's apps; a faint fill only
            // under the pointer, reaching into the margin so the row's
            // content stays aligned with the page.
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.06 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, -10)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// One agent in focus under a bare "‹": its mark and name, its
// CLI, then whether it runs (once registered), Workspace, Fast mode near
// the top, Model and Effort.
// Each change writes its agent.json (SettingsModel.save); until it has a
// workspace, a new agent's changes wait for one.
private struct AgentDetail: View {
    @ObservedObject var agent: AgentChoice
    let model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            backButton
            ScrollView {
                page
                    // The page's margin, given back inside the scroll view
                    // so the scroller sits at the window's edge.
                    .padding(.trailing, 32)
            }
            .scrollIndicators(.visible)
            .padding(.trailing, -32)
        }
    }

    private var backButton: some View {
            Button { model.back() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Agents") // TODO(copy): copy
            .accessibilityLabel("Back to Agents") // TODO(copy): copy
            .padding(.top, -28)
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    AgentMark(harness: agent.harness, size: 18, ink: .primary)
                    Text(agent.name).font(.title3.weight(.semibold))
                }
                Text(agent.cliLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if agent.isRegistered {
                PillRow("Enabled", note: agent.enabled ? nil : "Not started and not in the composer's rotation") { // TODO(copy): copy
                    PillSwitch(label: "Enabled", isOn: Binding( // TODO(copy): copy
                        get: { agent.enabled },
                        set: { agent.enabled = $0; model.save(agent) }
                    ))
                }
            }
            PillRow("Workspace", note: workspaceNote) { // TODO(copy): copy
                Button {
                    if let window = model.window { agent.chooseFolder(in: window) { model.save(agent) } }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder").font(.system(size: 11))
                        Text(agent.workspaceName ?? "Choose…") // TODO(copy): copy
                    }
                }
                .buttonStyle(.pill)
            }
            .disabled(agent.executable == nil)
            Group {
                PillRow("Fast mode") { // TODO(copy): copy
                    PillSwitch(label: "Fast mode", isOn: Binding( // TODO(copy): copy
                        get: { agent.fast },
                        set: { agent.fast = $0; model.save(agent) }
                    ))
                }
                PillRow("Model") { // TODO(copy): copy
                    PillMenu(title: agent.modelLabel(agent.model)) {
                        ForEach(agent.modelOptions, id: \.self) { option in
                            Button {
                                agent.model = option
                                model.save(agent)
                            } label: {
                                if let logo = agent.modelMaker(option).flatMap(AgentMarks.maker) {
                                    Label { Text(agent.modelLabel(option)) } icon: { Image(nsImage: logo) }
                                } else {
                                    Text(agent.modelLabel(option))
                                }
                            }
                        }
                    }
                }
                PillRow("Effort") { // TODO(copy): copy
                    PillMenu(title: AgentChoice.effortLabel(agent.effort)) {
                        ForEach(agent.effortOptions, id: \.self) { option in
                            Button(AgentChoice.effortLabel(option)) { agent.effort = option; model.save(agent) }
                        }
                    }
                }
            }
            .disabled(agent.executable == nil)
            TrustedFoldersGrid(agent: agent, model: model)
                .padding(.top, 8)
                .disabled(agent.executable == nil)
        }
    }

    // The workspace's path; or, for an agent not yet registered, that one
    // starts it.
    private var workspaceNote: String? {
        if let root = agent.root, agent.isRegistered { return (root as NSString).abbreviatingWithTildeInPath }
        guard agent.executable != nil else { return nil }
        return "Choose one to start \(agent.name)" // TODO(copy): copy
    }
}

// The speech model dictation uses, chosen from ParrotCore's registry; a
// choice is written through (UserDefaults' dictation.model) and applied at
// once (DictationService.applyModel), so the next hold dictates with it.
// Its download, when the weights are not on disk, starts silently and
// shows in the pill on the next press.
private struct DictationPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        SettingsGroup("Dictation") { // TODO(copy): copy
            PillRow("Model", note: model.dictationNote) { // TODO(copy): copy
                PillMenu(title: model.dictation.displayName) {
                    ForEach(model.dictationOptions, id: \.id) { option in
                        Button(SettingsModel.dictationOptionLabel(option)) {
                            model.selectDictation(model: option)
                        }
                    }
                }
            }
        }
    }
}

// What the Context pane shows and changes: Sirius's defaults, read when the
// pane opens. The composer and dictation read the same keys at each
// message, so a switch takes effect at the next one.
@MainActor
final class ContextSettings: ObservableObject {
    private let defaults: UserDefaults
    // The apps that have given context as providers (ContextProviders).
    let providers: [ContextProviders.Seen]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        providers = ContextProviders.seen(in: defaults).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var enabled: Bool {
        get { SettingsKeys.ambientContextEnabled(in: defaults) }
        set { set(newValue, SettingsKeys.ambientContext) }
    }

    // The warning before context from a sensitive app is sent
    // (ContextWarnings). Turning it on warns for every app again.
    var warns: Bool {
        get { ContextWarnings.isEnabled(in: defaults) }
        set {
            objectWillChange.send()
            ContextWarnings.setEnabled(newValue, in: defaults)
            SiriusLog.onboarding.info("settings: \(ContextWarnings.enabledKey) \(newValue ? "on" : "off")")
        }
    }

    // On Sirius's list, or an app that has marked its own context so.
    func isSensitive(_ id: String) -> Bool { ContextWarnings.isSensitive(id, in: defaults) }

    func isOn(_ app: NativeApp) -> Bool { NativeApps.isOn(app, in: defaults) }
    func set(_ app: NativeApp, on: Bool) { set(on, NativeApps.key(app)) }
    func isOn(_ provider: ContextProviders.Seen) -> Bool { ContextProviders.isOn(provider.id, in: defaults) }
    func set(_ provider: ContextProviders.Seen, on: Bool) { set(on, ContextProviders.key(provider.id)) }

    private func set(_ value: Bool, _ key: String) {
        objectWillChange.send()
        defaults.set(value, forKey: key)
        SiriusLog.onboarding.info("settings: \(key) \(value ? "on" : "off")")
    }
}

// The master switch, then the apps that give context themselves, then the
// apps Sirius reads through Accessibility, each with a switch.
private struct ContextPane: View {
    @ObservedObject var context: ContextSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SettingsGroup("Ambient Context", // TODO(copy): copy
                              // TODO(copy): copy
                              note: "Sends what you have open and selected in the app in front with your message.") {
                    PillRow("Use ambient context") { // TODO(copy): copy
                        PillSwitch(label: "Use ambient context", isOn: Binding(
                            get: { context.enabled }, set: { context.enabled = $0 }))
                    }
                    PillRow("Warn before sending from sensitive apps") { // TODO(copy): copy
                        PillSwitch(label: "Warn before sending from sensitive apps", isOn: Binding(
                            get: { context.warns }, set: { context.warns = $0 }))
                    }
                    .disabled(!context.enabled)
                }
                separator
                VStack(alignment: .leading, spacing: 10) {
                    heading("Apps that share natively", // TODO(copy): copy
                            note: "These apps tell Sirius what you have open themselves.") // TODO(copy): copy
                    if context.providers.isEmpty {
                        Text("None yet. An app appears here the first time it gives Sirius context.") // TODO(copy): copy
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    ForEach(context.providers) { provider in
                        ContextAppRow(bundleID: provider.id, name: provider.name, path: provider.path,
                                      sensitive: context.isSensitive(provider.id), isOn: Binding(
                            get: { context.isOn(provider) }, set: { context.set(provider, on: $0) }))
                    }
                }
                .disabled(!context.enabled)
                separator
                VStack(alignment: .leading, spacing: 10) {
                    heading("Onscreen", // TODO(copy): copy
                            // TODO(copy): copy
                            note: "Sirius reads what is open and selected in these apps. Needs Accessibility.")
                    ForEach(NativeApps.all, id: \.id) { app in
                        ContextAppRow(bundleID: app.id, name: app.name,
                                      sensitive: app.sensitive,
                                      isOn: Binding(get: { context.isOn(app) }, set: { context.set(app, on: $0) }))
                    }
                }
                .disabled(!context.enabled)
            }
            // 32 less the width the scroller keeps for itself, so rows end
            // where the other pages' rows do.
            .padding(.trailing, 16)
        }
        // Shown when the list is longer than the window, so it is plain
        // there is more below.
        .scrollIndicators(.visible)
        // The scroller sits at the window's edge, in the page's own margin.
        .padding(.trailing, -32)
    }

    // A thin line between the page's sections.
    private var separator: some View {
        Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
    }

    private func heading(_ title: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 13, weight: .medium))
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// One app: its macOS icon, its name and a switch.
private struct ContextAppRow: View {
    let bundleID: String
    let name: String
    var path: String?
    // Sirius warns before sending from it: a short label by the switch.
    let sensitive: Bool
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let icon = Self.icon(bundleID, path: path) {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
                }
            }
            .frame(width: 22, height: 22)
            Text(name)
            Spacer(minLength: 12)
            if sensitive {
                Text("Sensitive") // TODO(copy): copy
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Sirius asks before sending context from this app.") // TODO(copy): copy
            }
            PillSwitch(label: name, isOn: $isOn)
        }
        .padding(.vertical, 2)
        .opacity(isEnabled ? 1 : 0.5)
    }

    // The app where the system finds it; failing that where it last ran
    // from, or where it is running now.
    private static func icon(_ bundleID: String, path: String?) -> NSImage? {
        let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path
            ?? path.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
            ?? NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.bundleURL?.path
        guard let found else { return nil }
        return NSWorkspace.shared.icon(forFile: found)
    }
}

// The folders the agent's harness already trusts, as chips: the workspace
// lit, a click on another makes it the workspace, + chooses any folder.
// Read from the harness's own files each time the page opens; Sirius never
// changes what a harness trusts.
private struct TrustedFoldersGrid: View {
    @ObservedObject var agent: AgentChoice
    let model: SettingsModel
    @State private var folders: [String]?
    @State private var showsAll = false
    // Chips shown before "+N more".
    static let shown = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Trusted folders").font(.system(size: 13, weight: .medium)) // TODO(copy): copy
                Button {
                    if let window = model.window { agent.chooseFolder(in: window) { model.save(agent) } }
                } label: {
                    Image(systemName: "plus.circle").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Choose another folder to work in") // TODO(copy): copy
            }
            Text(note).font(.caption).foregroundStyle(.secondary)
            if let folders, !folders.isEmpty {
                ChipFlow(spacing: 8) {
                    ForEach(visible(folders), id: \.self) { folder in
                        FolderChip(folder: folder, current: folder == agent.root) {
                            agent.use(folder)
                            model.save(agent)
                        }
                    }
                    if !showsAll, folders.count > Self.shown {
                        Button { showsAll = true } label: {
                            Text("+\(folders.count - Self.shown) more") // TODO(copy): copy
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .frame(height: 28)
                                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.25),
                                                                style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .task(id: agent.harness) {
            let harness = agent.harness
            let read = model.trusted
            folders = await Task.detached { read(harness) }.value
        }
    }

    private var note: String {
        let product = AgentChoice.product(agent.harness)
        guard let folders else { return "" }
        if folders.isEmpty {
            return agent.harness == .cursor
                ? "\(product) does not say which folders it trusts." // TODO(copy): copy
                : "\(product) trusts no folders yet." // TODO(copy): copy
        }
        return "Folders \(product) already trusts. Click one to work there." // TODO(copy): copy
    }

    private func visible(_ folders: [String]) -> [String] {
        showsAll ? folders : Array(folders.prefix(Self.shown))
    }
}

private struct FolderChip: View {
    let folder: String
    let current: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: current ? "folder.fill" : "folder").font(.system(size: 11))
                Text((folder as NSString).lastPathComponent).font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 200, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(current ? .primary : .secondary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Capsule().fill(Color.primary.opacity(current ? 0.16 : 0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help((folder as NSString).abbreviatingWithTildeInPath)
    }
}

// Lays its children out left to right, wrapping to a new row when the
// next would not fit.
private struct ChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
