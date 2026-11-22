import AppKit
import SiriusAdapters
import SiriusCore
import SiriusProtocol
import SwiftUI

// The onboarding's one sheet over the still sky (NightSky, its own hosting
// view), laid out as Parrot's: the star as its badge, the
// wordmark alone, then a grid of rows (the two shortcuts,
// Microphone and Accessibility), the folders line, and Get Started, with
// the privacy line under it. The folders line's Change or Choose swaps the
// sheet for the agents, a list then one agent in focus (OnboardingPane),
// in the same window.
struct OnboardingView: View {
    // The sheet's insets, and the gap between the rows' groups.
    static let top: CGFloat = 40
    static let bottom: CGFloat = 26
    static let groupGap: CGFloat = 10
    // The agents panes' width and top inset.
    static let paneWidth: CGFloat = 400
    static let paneTop: CGFloat = 56

    @ObservedObject var model: OnboardingModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            WindowDragArea()
            Group {
                switch model.pane {
                case .sheet: sheet
                case .agents: AgentsList(model: model)
                case .agent(let harness):
                    if let agent = model.agent(harness) {
                        AgentFocus(agent: agent, back: { model.pane = .agents },
                                   window: { [weak model] in model?.window })
                    }
                }
            }
            .id(model.pane)
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6)))
        }
        .frame(width: OnboardingWindow.size.width, height: OnboardingWindow.size.height, alignment: .topLeading)
        .environment(\.colorScheme, .dark)
        .animation(.easeOut(duration: 0.2), value: model.pane)
    }

    private var sheet: some View {
        VStack(spacing: 0) {
            BloomStar()
                .scaleEffect(0.75)
                .frame(width: BloomStar.side * 0.75, height: BloomStar.side * 0.75)
            Wordmark(text: "Sirius")
                .padding(.top, 14)

            rows
                .padding(.top, 36)

            Spacer(minLength: 24)

            Button("Get Started") { model.getStarted() } // TODO(copy): copy
                .buttonStyle(SkyPillStyle(kind: .primary, large: true))
                .disabled(!model.canGetStarted)
            LockFooter()
                .padding(.top, 14)
        }
        .padding(.top, Self.top)
        .padding(.bottom, Self.bottom)
        .frame(width: OnboardingWindow.size.width, height: OnboardingWindow.size.height, alignment: .top)
    }

    // The four rows as one block, sized to its content and centered on the
    // sheet like a margin-auto div, with labels and values left-aligned in
    // their columns. The workspaces line sits below, centered on
    // its own, so its width never widens or moves the block.
    private var rows: some View {
        VStack(spacing: 0) {
            Grid(alignment: .leading, horizontalSpacing: 60, verticalSpacing: 6) {
                ShortcutRows(shortcuts: model.shortcuts, window: { [weak model] in model?.window })
                PermissionRows(grants: model.grants)
                    .padding(.top, Self.groupGap)
            }
            .fixedSize()
            .frame(maxWidth: .infinity)
            FoldersLine(text: model.foldersLine, help: model.foldersHelp, action: model.foldersAction) {
                model.pane = .agents
            }
            .fixedSize()
            .frame(maxWidth: .infinity)
            .padding(.top, Self.groupGap + 6)
        }
    }
}

// A row's label, left-aligned in the grid's first column.
private func rowLabel(_ text: String) -> some View {
    Text(text)
        .font(.system(size: 13))
        .foregroundStyle(NightSkyPalette.text)
}

// The two ways in, each shortcut as plain glyph text, and each rebindable
// in place (ShortcutsModel): a click on Compose's records a new one, a
// click on Hold to talk's offers the keys it can be.
private struct ShortcutRows: View {
    @ObservedObject var shortcuts: ShortcutsModel
    let window: () -> NSWindow?

    var body: some View {
        GridRow {
            rowLabel("Hold to talk") // TODO(copy): copy
            ShortcutButton(text: shortcuts.holdKey.glyph, active: false) {
                if let view = window()?.contentView { shortcuts.showHoldKeyMenu(in: view) }
            }
        }
        GridRow {
            rowLabel("Compose") // TODO(copy): copy
            ShortcutButton(text: shortcuts.composeText, active: shortcuts.isRecording) {
                shortcuts.isRecording ? shortcuts.cancelRecording() : shortcuts.startRecording(in: window())
            }
            .onDisappear { shortcuts.cancelRecording() }
        }
    }

}

// Microphone then Accessibility, each with its own Allow pill, which
// prompts or opens the pane (Grants.allowSteps); granted, a check and
// "Allowed". Live as the grants arrive (GrantsModel polls).
private struct PermissionRows: View {
    @ObservedObject var grants: GrantsModel

    var body: some View {
        GridRow {
            rowLabel("Microphone") // TODO(copy): copy
            permission(.microphone)
        }
        GridRow {
            rowLabel("Accessibility") // TODO(copy): copy
            permission(.accessibility)
        }
        if grants.parrotRunning {
            // Sirius owns fn and Parrot is being retired.
            GridRow {
                Text("Quit Parrot so fn isn't handled twice.") // TODO(copy): copy
                    .font(.system(size: 12))
                    .foregroundStyle(NightSkyPalette.secondary)
                    .gridCellColumns(2)
            }
        }
    }

    @ViewBuilder
    private func permission(_ grant: Grant) -> some View {
        if grants.isGranted(grant) {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                Text("Allowed") // TODO(copy): copy
                    .font(.system(size: 12))
            }
            .foregroundStyle(NightSkyPalette.success)
            .frame(height: SkyPillStyle.height)
        } else {
            Button("Allow") { grants.allow(grant) } // TODO(copy): copy
                // Filled, so the missing grants read as what to do next.
                .buttonStyle(SkyPillStyle(kind: .primary))
                // Off while it would do nothing: a prompt is up, or the
                // microphone request waits for the plist key.
                .disabled(grants.steps(grant).isEmpty)
        }
    }
}

// The agents' folders in one line under the grid: "Using N folders you
// trust in Claude Code and Codex · Change" while they work in folders their
// harnesses trust, otherwise the folders chosen or a request
// to choose one. The link opens the agents list.
private struct FoldersLine: View {
    let text: String
    let help: String
    let action: String
    let open: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "folder")
                .font(.system(size: 11))
            Text(text)
                .lineLimit(1)
                .fixedSize()
                .help(help)
            Text("·")
            TextLink(title: action, action: open)
        }
        .font(.system(size: 12))
        .foregroundStyle(NightSkyPalette.secondary)
        .frame(height: SkyPillStyle.height)
    }
}

// The agents: each agent's mark, name and a one-line
// summary of its folder, with a chevron; a click puts it in focus. Done goes
// back to the sheet.
private struct AgentsList: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Agents") // TODO(copy): copy
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(NightSkyPalette.text)
            Text("Each agent works in its own workspace.") // TODO(copy): copy
                .font(.system(size: 12))
                .foregroundStyle(NightSkyPalette.secondary)
                .padding(.top, 6)
            VStack(spacing: 8) {
                ForEach(model.ordered) { agent in
                    AgentListRow(agent: agent) { model.pane = .agent(agent.harness) }
                }
            }
            .padding(.top, 22)
            Spacer(minLength: 24)
            Button("Done") { model.pane = .sheet } // TODO(copy): copy
                .buttonStyle(SkyPillStyle(kind: .primary, large: true))
                .frame(maxWidth: .infinity)
        }
        .frame(width: OnboardingView.paneWidth, alignment: .leading)
        .padding(.top, OnboardingView.paneTop)
        .padding(.bottom, OnboardingView.bottom + 33)
        .frame(width: OnboardingWindow.size.width, height: OnboardingWindow.size.height, alignment: .top)
    }
}

private struct AgentListRow: View {
    @ObservedObject var agent: AgentChoice
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                AgentMark(harness: agent.harness, size: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(AgentMark.label(agent.harness))
                        .font(.system(size: 13))
                        .foregroundStyle(NightSkyPalette.text)
                    Text(summary)
                        .font(.system(size: 11.5))
                        .foregroundStyle(NightSkyPalette.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(NightSkyPalette.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.08 : 0.05)))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    // Its folder, and whose trust it comes from; or why it has none.
    private var summary: String {
        if !agent.looking, agent.executable == nil { return "Not installed" } // TODO(copy): copy
        guard let root = agent.root else { return "No workspace yet" } // TODO(copy): copy
        let path = (root as NSString).abbreviatingWithTildeInPath
        guard agent.usesTrusted else { return path }
        return "\(path) · trusted in \(AgentChoice.product(agent.harness))" // TODO(copy): copy
    }
}

// One agent in focus: "‹" back to the list, its mark and name, where its
// CLI is, and its Workspace (its folder), with a pill that opens
// the folder panel.
private struct AgentFocus: View {
    @ObservedObject var agent: AgentChoice
    let back: () -> Void
    let window: () -> NSWindow?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextLink(title: "‹", secondary: true, action: back)
                .font(.system(size: 20))
                .help("Agents") // TODO(copy): copy
                .accessibilityLabel("Back to Agents") // TODO(copy): copy
                .padding(.top, -28)
            HStack(spacing: 8) {
                AgentMark(harness: agent.harness, size: 18)
                Text(AgentMark.label(agent.harness))
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(NightSkyPalette.text)
            }
            .padding(.top, 14)
            Text(agent.cliLine)
                .font(.system(size: 11.5))
                .foregroundStyle(NightSkyPalette.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.top, 6)
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Workspace") // TODO(copy): copy
                        .font(.system(size: 13))
                        .foregroundStyle(NightSkyPalette.text)
                    ForEach(notes, id: \.self) { note in
                        Text(note)
                            .font(.system(size: 11.5))
                            .foregroundStyle(NightSkyPalette.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
                folderPill
            }
            .padding(.top, 24)
            Spacer()
        }
        .frame(width: OnboardingView.paneWidth, alignment: .leading)
        .padding(.top, OnboardingView.paneTop + 28)
        .frame(width: OnboardingWindow.size.width, height: OnboardingWindow.size.height, alignment: .top)
    }

    // The workspace's path, and whose trust it comes from.
    private var notes: [String] {
        guard let root = agent.root else { return [] }
        let path = (root as NSString).abbreviatingWithTildeInPath
        guard agent.usesTrusted else { return [path] }
        return [path, "Trusted in \(AgentChoice.product(agent.harness))"] // TODO(copy): copy
    }

    @ViewBuilder
    private var folderPill: some View {
        Button { if let window = window() { agent.chooseFolder(in: window) } } label: {
            HStack(spacing: 7) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(NightSkyPalette.primary)
                    .frame(width: 15, height: 15)
                Text(folder)
                    .foregroundStyle(agent.root == nil ? NightSkyPalette.secondary : NightSkyPalette.text)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .buttonStyle(SkyPillStyle(kind: .outline))
        .disabled(agent.executable == nil)
    }

    private var folder: String {
        agent.workspaceName ?? "Select" // TODO(copy): copy
    }
}

// An agent's mark (AgentMarks) in its maker's colors, as the composer and
// the toast draw it: Claude's orange, Gemini's gradient sparkle, Meta's
// blue for Muse. The two one-color marks, Codex's and Cursor's, take
// `ink` instead: white on the onboarding's sky, the text color in Settings.
// A disabled row does not gray it out.
struct AgentMark: View {
    let harness: AgentRegistration.Harness
    let size: CGFloat
    var ink: Color = .white

    static func inked(_ harness: AgentRegistration.Harness) -> Bool {
        harness == .codex || harness == .cursor || harness == .opencode
    }

    var body: some View {
        if let mark = AgentMarks.mark(agent: AgentChoice.id(harness), harness: harness) {
            Image(nsImage: mark)
                .renderingMode(Self.inked(harness) ? .template : .original)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(ink)
                .frame(width: size, height: size)
        }
    }

    // The label for the Codex agent is ChatGPT / Codex.
    static func label(_ harness: AgentRegistration.Harness) -> String {
        switch harness {
        case .claudeCode: "Claude"
        case .codex: "ChatGPT / Codex"
        case .museCode: "Muse"
        case .cursor: "Cursor"
        case .antigravity: "Gemini / Antigravity"
        case .opencode: "OpenCode"
        }
    }
}

// A shortcut as glyphs, SF Pro 13 in the secondary colour, tracked 4%; the
// whole text is the hit target, with a faint 5% white pill under the
// pointer and while recording.
struct ShortcutButton: View {
    let text: String
    let active: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 13))
                .tracking(13 * 0.04)
                .foregroundStyle(NightSkyPalette.secondary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 10)
                .frame(height: SkyPillStyle.height)
                .background(Capsule().fill(Color.white.opacity(hovering || active ? 0.05 : 0)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.leading, -10)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering || active)
    }
}

// A text link: Change and Choose in the pill's colour, "‹" in the
// secondary; each brightens under the pointer.
private struct TextLink: View {
    let title: String
    var secondary = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .foregroundStyle(hovering ? Color.white : (secondary ? NightSkyPalette.secondary : NightSkyPalette.primary))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// "Speech recognition runs on your Mac." with a lock, centred under Get
// Started.
private struct LockFooter: View {
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "lock.fill")
                .font(.system(size: 9))
                .frame(width: 11, height: 11)
            Text("Speech recognition runs on your Mac.")
                .font(.system(size: 11.5))
        }
        .foregroundStyle(NightSkyPalette.secondary)
        .allowsHitTesting(false)
    }
}

// The onboarding's pills: 27 tall, radius 14.5, SF Pro 12, the label's ink
// 12 pt from the left edge and 13 from the right. Primary is filled #E6FAFF
// with a #050506 label (Allow); outline has a #171719 stroke and a
// secondary label (the folder pills). Large is Get Started's: 34 tall,
// SF Pro 13 medium, wider.
struct SkyPillStyle: ButtonStyle {
    enum Kind { case primary, outline }

    static let height: CGFloat = 27
    static let largeHeight: CGFloat = 34
    let kind: Kind
    var large = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 13 : 12, weight: large ? .medium : .regular))
            .foregroundStyle(kind == .primary ? NightSkyPalette.onPrimary : NightSkyPalette.secondary)
            .padding(.leading, large ? 28 : (kind == .primary ? 12 : 9))
            .padding(.trailing, large ? 28 : (kind == .primary ? 13 : 11))
            .frame(height: large ? Self.largeHeight : Self.height)
            .background {
                switch kind {
                case .primary: Capsule().fill(NightSkyPalette.primary)
                case .outline: Capsule().strokeBorder(NightSkyPalette.stroke, lineWidth: 1)
                }
            }
            .contentShape(Capsule())
            .opacity((isEnabled ? 1 : 0.35) * (configuration.isPressed ? 0.8 : 1))
    }
}

// Drags the window from anywhere the sheet has no control: a borderless
// window has no title bar, and SwiftUI's views don't move the window on
// their own.
private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}
