import AppKit
import SiriusAdapters
import SiriusCore
import SiriusProtocol
import SwiftUI

// The onboarding's four pages over the still sky (NightSky, its own hosting
// view), as the design's frames have them: the welcome's lockup, then
// Agents, Permissions (and its granted state) and Done, each a title, a subtitle and two rows. Each page
// crossfades in as the step changes, rising 8 pt into place; with Reduce
// Motion it is a plain fade. No buttons in the pages: the dots, Return, →
// and ← move between them (OnboardingKeys), and an arrow bottom-right
// does what → does. The "?" sits bottom-left. The welcome is a preface with
// no dots, and moves on by itself; the three steps after it have one each.
struct OnboardingView: View {
    // The frames' places, in the 760 x 540 window: the star's centre
    // (39:2, turned, so its box centre), the wordmark's and the tagline's.
    static let starY: CGFloat = 164.8
    static let wordmarkY: CGFloat = 255.6
    static let taglineY: CGFloat = 304.6
    // The steps' title, subtitle and rows (top edges), and the rows' width.
    static let titleY: CGFloat = 171
    static let rowsWidth: CGFloat = 360
    // The lock footer's and the dots' top edges.
    static let footerY: CGFloat = 466
    static let dotsY: CGFloat = 510
    // The bottom corners: the "?" bottom-left, the arrow or Skip
    // bottom-right, each glyph 24 pt in from its edge and centred on the
    // "?"'s old line (its 18 pt ring's top was at 504), each target at
    // least 24 pt square.
    static let cornerInset: CGFloat = 24
    static let cornerMidY: CGFloat = 513
    static let target: CGFloat = 24
    // The first turn's waiting line, under the rows. Not in the frames.
    static let waitingY: CGFloat = 352
    // The blur the lockup comes in from, and how far it moves up.
    static let blurRadius: CGFloat = 16
    static let lockupRise: CGFloat = 10
    // How far a step's content rises as it crossfades in.
    static let pageRise: CGFloat = 8
    static let pageFade = 0.35

    @ObservedObject var model: OnboardingModel
    @ObservedObject private var intro: OnboardingIntro
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: OnboardingModel) {
        self.model = model
        intro = model.intro
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            WindowDragArea(onClick: { model.clickedBackground() })
            ZStack(alignment: .top) {
                page(model.step)
                    .id(model.step)
                    .transition(pageTransition)
            }
            .frame(width: OnboardingWindow.size.width, height: OnboardingWindow.size.height, alignment: .top)

            if model.step.dot != nil {
                StepDots(current: model.step, canContinue: model.canContinue) { model.go(to: $0) }
                    .frame(width: OnboardingWindow.size.width)
                    .offset(y: Self.dotsY)
                    .transition(.opacity)
            }

            HelpButton()
                .offset(x: Self.cornerInset - (Self.target - HelpButton.ring) / 2,
                        y: Self.cornerMidY - Self.target / 2)
                .opacity(intro.settle)

            if model.step.next != nil {
                NextArrow(enabled: model.takesInput && model.canContinue, action: model.next)
                    .frame(width: OnboardingWindow.size.width - Self.cornerInset + NextArrow.overhang,
                           alignment: .trailing)
                    .offset(y: Self.cornerMidY - Self.target / 2)
                    .opacity(intro.settle)
                    .transition(.opacity)
            }
        }
        .frame(width: OnboardingWindow.size.width, height: OnboardingWindow.size.height, alignment: .topLeading)
        .environment(\.colorScheme, .dark)
        .animation(.easeOut(duration: Self.pageFade), value: model.step)
    }

    private var pageTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(insertion: .opacity.combined(with: .offset(y: Self.pageRise)), removal: .opacity)
    }

    @ViewBuilder
    private func page(_ step: OnboardingStep) -> some View {
        switch step {
        case .welcome:
            lockup
        case .agents:
            StepPage(title: "Agents", // TODO(andrew): copy
                     subtitle: "Choose where your agents will work.") { // TODO(andrew): copy
                AgentsRows(model: model)
            }
        case .permissions:
            ZStack(alignment: .topLeading) {
                StepPage(title: "Permissions", // TODO(andrew): copy
                         subtitle: "Allow these so you can hold fn and talk.") { // TODO(andrew): copy
                    PermissionRows(grants: model.grants)
                }
                LockFooter()
            }
        case .done:
            ZStack(alignment: .topLeading) {
                StepPage(title: "The sky is listening.", subtitle: doneSubtitle,
                         subtitleColour: doneSubtitleColour) {
                    ShortcutRows(shortcuts: model.shortcuts, turn: model.firstTurn,
                                 window: { [weak model] in model?.window })
                }
                if case .answering(_, let agent) = model.firstTurn {
                    Text("\(agent) is answering…") // TODO(andrew): copy
                        .font(.system(size: 12))
                        .foregroundStyle(NightSkyPalette.secondary)
                        .frame(width: OnboardingWindow.size.width)
                        .offset(y: Self.waitingY)
                        .transition(.opacity)
                }
                LockFooter()
                SkipLink(action: model.finish)
                    .frame(width: OnboardingWindow.size.width - Self.cornerInset, alignment: .trailing)
                    .offset(y: Self.cornerMidY - Self.target / 2)
            }
            .animation(.easeOut(duration: 0.25), value: model.firstTurn)
        }
    }

    // The last page's subtitle through the first turn: the approved line
    // (A), "Listening…" while fn is held (B), the transcript in quotes (C),
    // then the composer's shortcut, as bound (D).
    private var doneSubtitle: String {
        switch model.firstTurn {
        case .ready: "Hold \(model.shortcuts.holdKey.glyph) and say, “Hello, what can you do?”"
        case .listening: "Listening…"
        case .answering(let transcript, _): "“\(transcript)”"
        case .composing: "Now press \(KeyComboText.string(model.shortcuts.compose)) to compose."
        }
    }

    private var doneSubtitleColour: Color {
        if case .answering = model.firstTurn { return NightSkyPalette.transcript }
        return NightSkyPalette.secondary
    }

    // The star, the wordmark and the tagline at the frame's places, coming
    // in with the intro's reveal.
    private var lockup: some View {
        let reveal = CGFloat(intro.reveal)
        return ZStack(alignment: .top) {
            BloomStar(twinkles: !reduceMotion)
                .position(x: OnboardingWindow.size.width / 2, y: Self.starY)
            Wordmark(text: "Sirius")
                .position(x: OnboardingWindow.size.width / 2, y: Self.wordmarkY)
            Text("ambient magic")
                .font(.system(size: 12))
                .tracking(12 * 0.16)
                .foregroundStyle(NightSkyPalette.tagline)
                .position(x: OnboardingWindow.size.width / 2, y: Self.taglineY)
        }
        .frame(width: OnboardingWindow.size.width, height: OnboardingWindow.size.height)
        .offset(y: reduceMotion ? 0 : (1 - reveal) * Self.lockupRise)
        .blur(radius: reduceMotion ? 0 : (1 - reveal) * Self.blurRadius)
        .opacity(intro.reveal)
        .allowsHitTesting(false)
    }
}

// A step's title, subtitle and rows, centred, the title's top at 171 and the
// rows' at 248 (64:14, 63:14, 115:319).
struct StepPage<Rows: View>: View {
    let title: String
    let subtitle: String
    var subtitleColour: Color = NightSkyPalette.secondary
    @ViewBuilder let rows: () -> Rows

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(NightSkyPalette.text)
                .frame(height: 24)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(subtitleColour)
                .lineLimit(1)
                .frame(height: 15)
                .padding(.top, 9)
            VStack(spacing: 6) {
                rows()
            }
            .padding(.top, 29)
        }
        .frame(width: OnboardingView.rowsWidth)
        .padding(.top, OnboardingView.titleY)
        .frame(width: OnboardingWindow.size.width, alignment: .top)
    }
}

// One row: a 22 pt icon at 85%, its label in SF Pro 18, and what to do on
// the right, 36 tall.
struct StepRow<Icon: View, Trailing: View>: View {
    let label: String
    @ViewBuilder let icon: () -> Icon
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            icon()
                .frame(width: 22, height: 22)
                .opacity(0.85)
            Text(label)
                .font(.system(size: 18))
                .foregroundStyle(NightSkyPalette.text)
            Spacer(minLength: 12)
            trailing()
        }
        .frame(height: 36)
    }
}

// ChatGPT (Codex) then Claude, each with its mark and a Select pill that
// opens the folder panel; once a folder is chosen, the pill shows its name.
// No folder is chosen for the user.
private struct AgentsRows: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        ForEach(ordered) { agent in
            // The window is read as the pill is clicked; it is set after the
            // page is first drawn.
            AgentRow(agent: agent, window: { [weak model] in model?.window })
        }
    }

    // The frame's order: ChatGPT first.
    private var ordered: [AgentChoice] {
        model.agents.sorted { order($0.harness) < order($1.harness) }
    }

    private func order(_ harness: AgentRegistration.Harness) -> Int {
        switch harness {
        case .codex: 0
        case .claudeCode: 1
        }
    }
}

private struct AgentRow: View {
    @ObservedObject var agent: AgentChoice
    let window: () -> NSWindow?

    var body: some View {
        StepRow(label: Self.label(agent.harness)) {
            // The mark's file (AgentMarks), in one colour.
            if let mark = AgentMarks.mark(agent: AgentChoice.id(agent.harness), harness: agent.harness) {
                Image(nsImage: mark)
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(Self.colour(agent.harness))
                    .frame(width: 20, height: 20)
            }
        } trailing: {
            if !agent.looking, agent.executable == nil {
                Text("Not installed") // TODO(andrew): copy
                    .font(.system(size: 12))
                    .foregroundStyle(NightSkyPalette.secondary)
                    .help("\(AgentDetector.command(for: agent.harness)) was not found") // TODO(andrew): copy
            } else {
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
                .help(agent.root.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "")
            }
        }
    }

    // The folder's name, its middle cut past 20 characters, so the pill
    // hugs its label.
    private var folder: String {
        guard let root = agent.root else { return "Select" }
        let name = (root as NSString).lastPathComponent
        guard name.count > 20 else { return name }
        return "\(name.prefix(10))…\(name.suffix(9))"
    }

    // The label for the Codex agent is ChatGPT.
    static func label(_ harness: AgentRegistration.Harness) -> String {
        switch harness {
        case .claudeCode: "Claude"
        case .codex: "ChatGPT"
        }
    }

    // The Claude mark in its own orange (#D97757); any other mark white.
    static func colour(_ harness: AgentRegistration.Harness) -> Color {
        harness == .claudeCode ? NightSkyPalette.claude : Color.white
    }
}

// Microphone then Accessibility, each with its own Allow pill, which
// prompts or opens the pane (Grants.allowSteps); granted, a check and
// "Allowed". Live as the grants arrive (GrantsModel polls).
private struct PermissionRows: View {
    @ObservedObject var grants: GrantsModel

    var body: some View {
        StepRow(label: "Microphone") { // TODO(andrew): copy
            icon("mic")
        } trailing: {
            permission(.microphone)
        }
        StepRow(label: "Accessibility") { // TODO(andrew): copy
            icon("accessibility")
        } trailing: {
            permission(.accessibility)
        }
        if grants.parrotRunning {
            // Sirius owns fn and Parrot is being retired. Not in the frames.
            Text("Quit Parrot so fn isn't handled twice.") // TODO(andrew): copy
                .font(.system(size: 12))
                .foregroundStyle(NightSkyPalette.secondary)
                .padding(.top, 6)
        }
    }

    private func icon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17))
            .foregroundStyle(Color.white)
    }

    @ViewBuilder
    private func permission(_ grant: Grant) -> some View {
        if grants.isGranted(grant) {
            HStack(spacing: 5) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 15, height: 15)
                Text("Allowed") // TODO(andrew): copy
                    .font(.system(size: 12))
            }
            .foregroundStyle(NightSkyPalette.success)
            .frame(height: SkyPillStyle.height)
        } else {
            Button("Allow") { grants.allow(grant) }
                .buttonStyle(SkyPillStyle(kind: .primary))
                // Off while it would do nothing: a prompt is up, or the
                // microphone request waits for the plist key.
                .disabled(grants.steps(grant).isEmpty)
        }
    }
}

// The two ways in, each shortcut as plain glyph text, and each rebindable
// in place (ShortcutsModel): a click on Compose's records a new one, a
// click on hold to talk's offers the keys it can be.
// Each row dims and stops taking clicks as the first turn says: both from
// B, and in D all but Compose, whose shortcut the page then asks for.
private struct ShortcutRows: View {
    @ObservedObject var shortcuts: ShortcutsModel
    let turn: FirstTurn
    let window: () -> NSWindow?

    var body: some View {
        // The frame says "Push to talk"; the spec and the first-turn frames
        // "Hold to talk".
        StepRow(label: "Hold to talk") {
            symbol("waveform")
        } trailing: {
            ShortcutButton(text: shortcuts.holdKey.glyph, active: false) {
                if let view = window()?.contentView { shortcuts.showHoldKeyMenu(in: view) }
            }
        }
        .opacity(turn.holdRowOpacity)
        .allowsHitTesting(turn.holdRowEnabled)
        StepRow(label: "Compose") {
            symbol("keyboard")
        } trailing: {
            ShortcutButton(text: composeText, active: shortcuts.isRecording) {
                shortcuts.isRecording ? shortcuts.cancelRecording() : shortcuts.startRecording(in: window())
            }
            .onDisappear { shortcuts.cancelRecording() }
        }
        .opacity(turn.composeRowOpacity)
        .allowsHitTesting(turn.composeRowEnabled)
    }

    private var composeText: String {
        switch shortcuts.state {
        case .idle: KeyComboText.string(shortcuts.compose)
        case .recording(let hint): hint ?? "Press new shortcut…"
        case .refused(let text): text
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 17))
            .foregroundStyle(Color.white)
    }
}

// A shortcut as glyphs, SF Pro 13 in the secondary colour, tracked 4%; the
// whole text is the hit target, with a faint 5% white pill under the
// pointer and while recording (the spec; 116:33 is not in the file).
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
                .frame(height: 27)
                .background(Capsule().fill(Color.white.opacity(hovering || active ? 0.05 : 0)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering || active)
    }
}

// "Speech recognition runs on your Mac." with a lock, centred, 30 pt above
// the dots (63:14, 115:319).
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
        .frame(width: OnboardingWindow.size.width)
        .offset(y: OnboardingView.footerY)
        .allowsHitTesting(false)
    }
}

// Skip, bottom-right on the last page, where the arrow is on the others:
// done, and normal use. Its target is the arrow's height.
private struct SkipLink: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text("Skip")
                .font(.system(size: 12))
                .foregroundStyle(hovering ? NightSkyPalette.text : NightSkyPalette.secondary)
                .frame(minWidth: OnboardingView.target, minHeight: OnboardingView.target, alignment: .trailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// The "?" bottom-left on every page: an 18 pt ring with the glyph,
// opening the docs, in a 24 pt target.
private struct HelpButton: View {
    // TODO(andrew): the docs' address; a placeholder.
    static let docs = URL(string: "https://sirius.app/docs")!
    static let ring: CGFloat = 18
    @State private var hovering = false

    var body: some View {
        Button { NSWorkspace.shared.open(Self.docs) } label: {
            Text("?")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(hovering ? NightSkyPalette.text : NightSkyPalette.secondary)
                .frame(width: Self.ring, height: Self.ring)
                .overlay(Circle().strokeBorder(NightSkyPalette.stroke, lineWidth: 1))
                .frame(width: OnboardingView.target, height: OnboardingView.target)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Help") // TODO(andrew): copy
    }
}

// The arrow bottom-right on the welcome, agents and permissions pages:
// what → does, as a cue that the window moves on. Secondary, brightening
// under the pointer onto the shortcut rows' faint pill; at 30%, and not
// taking clicks, while → is held (no agent chosen yet).
private struct NextArrow: View {
    static let width: CGFloat = 28
    // How far the target reaches past the corner's inset, so the glyph is
    // centred where the "?"'s ring was.
    static let overhang: CGFloat = width / 2 - HelpButton.ring / 2
    let enabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.right")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(hovering && enabled ? NightSkyPalette.text : NightSkyPalette.secondary)
                .frame(width: Self.width, height: OnboardingView.target)
                .background(Capsule().fill(Color.white.opacity(hovering && enabled ? 0.05 : 0)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering && enabled)
        .help("Next") // TODO(andrew): copy
        .accessibilityLabel("Next") // TODO(andrew): copy
    }
}

// The onboarding's pills: 27 tall, radius 14.5, SF Pro 12,
// the label's ink 12 pt from the left edge and 13 from the right. Primary
// is filled #E6FAFF with a #050506 label (Allow, 56 wide); outline has a
// #171719 stroke and a secondary label (Select, with its folder icon).
struct SkyPillStyle: ButtonStyle {
    enum Kind { case primary, outline }

    static let height: CGFloat = 27
    let kind: Kind
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(kind == .primary ? NightSkyPalette.onPrimary : NightSkyPalette.secondary)
            .padding(.leading, kind == .primary ? 12 : 9)
            .padding(.trailing, kind == .primary ? 13 : 11)
            .frame(height: Self.height)
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

// Drags the window from anywhere the page has no control: a borderless
// window has no title bar, and SwiftUI's views don't move the window on
// their own.
private struct WindowDragArea: NSViewRepresentable {
    // A click that did not move the window.
    var onClick: () -> Void = {}

    func makeNSView(context: Context) -> NSView { DragView(onClick: onClick) }
    func updateNSView(_ view: NSView, context: Context) {
        (view as? DragView)?.onClick = onClick
    }

    private final class DragView: NSView {
        var onClick: () -> Void

        init(onClick: @escaping () -> Void) {
            self.onClick = onClick
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        override var mouseDownCanMoveWindow: Bool { true }

        // A click if the button comes up where it went down; a drag once
        // the pointer has moved a few points.
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            let start = event.locationInWindow
            while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
                if next.type == .leftMouseUp { return onClick() }
                if hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) > 3 {
                    return window.performDrag(with: next)
                }
            }
        }
    }
}

// Where the user is in the three steps, and the way between them: a click
// on a dot goes to its step (OnboardingModel.go). No chrome; a dot the
// click would reach brightens a little under the pointer. The welcome has
// none.
private struct StepDots: View {
    let current: OnboardingStep
    let canContinue: Bool
    let select: (OnboardingStep) -> Void
    @State private var hovered: OnboardingStep?

    static let dot: CGFloat = 6
    // Each dot's target: the dot with its share of the 6 pt gap either
    // side, so the dots sit as before, and taller, to be easier to hit.
    static let target = CGSize(width: 12, height: 20)

    var body: some View {
        HStack(spacing: 0) {
            ForEach(OnboardingStep.dotted, id: \.self) { step in
                Circle()
                    .fill(colour(step))
                    .frame(width: Self.dot, height: Self.dot)
                    .frame(width: Self.target.width, height: Self.target.height)
                    .contentShape(Rectangle())
                    .onTapGesture { select(step) }
                    .onHover { inside in
                        if inside { hovered = step } else if hovered == step { hovered = nil }
                    }
                    .accessibilityElement()
                    .accessibilityLabel("Step \((step.dot ?? 0) + 1) of \(OnboardingStep.dotted.count)") // TODO(andrew): copy
                    .accessibilityAddTraits(step == current ? [.isButton, .isSelected] : .isButton)
                    .accessibilityAction { select(step) }
            }
        }
        .animation(.easeOut(duration: 0.15), value: hovered)
        // The row keeps the dots' own height; the targets' extra overhangs.
        .padding(.vertical, -(Self.target.height - Self.dot) / 2)
    }

    private func colour(_ step: OnboardingStep) -> Color {
        if step == current { return NightSkyPalette.dot }
        let lit = hovered == step && reachable(step)
        return Color.white.opacity(lit ? 0.35 : 0.2)
    }

    private func reachable(_ step: OnboardingStep) -> Bool {
        step.rawValue < current.rawValue || (step.rawValue > current.rawValue && canContinue)
    }
}
