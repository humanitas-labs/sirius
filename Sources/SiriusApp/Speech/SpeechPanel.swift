import AppKit

// The speaking capsule: shown while an utterance plays, with the words as a
// caption, the agent under them, and a stop glyph. A click anywhere on it
// stops the utterance. Same dark glass as the toast, smaller.
//
// It sits at the top centre, under the menu bar, not at the bottom with the
// toast: speech is its own lane, so the two can be up at once and must not
// overlap, and the top right is Notification Center's.
// TODO(andrew): what speak's toast shows (captions or a speaking indicator,
// captions here), its place, and the final look.
@MainActor
final class SpeechPanel: NSPanel {
    var onStop: (() -> Void)?

    private static let width: CGFloat = 380
    private static let radius: CGFloat = 24
    // Gap below the menu bar.
    private static let margin: CGFloat = 12

    private let glyph = NSImageView()
    private let textLabel = NSTextField(wrappingLabelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let stopGlyph = NSImageView()
    private let capsule = StopView()
    private let row = NSStackView()
    private var agent = ""

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 64),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        // The toast panel's window behaviour: floats, never takes focus.
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        isMovable = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        appearance = NSAppearance(named: .darkAqua)

        capsule.onClick = { [weak self] in self?.onStop?() }

        glyph.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Speaking")
        glyph.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        glyph.contentTintColor = .white
        stopGlyph.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop speaking")
        stopGlyph.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 26, weight: .regular)
        stopGlyph.contentTintColor = NSColor(white: 1, alpha: 0.85)
        for view in [glyph, stopGlyph] {
            view.setContentHuggingPriority(.required, for: .horizontal)
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        textLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        textLabel.textColor = .white
        // A caption, not a transcript: up to 2,000 characters would not fit.
        textLabel.maximumNumberOfLines = 2
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.isSelectable = false
        textLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        detailLabel.font = .systemFont(ofSize: 13, weight: .medium)
        detailLabel.textColor = NSColor(white: 1, alpha: 0.55)

        let column = NSStackView(views: [textLabel, detailLabel])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2

        row.setViews([glyph, column, stopGlyph], in: .leading)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        row.edgeInsets = NSEdgeInsets(top: 14, left: 20, bottom: 14, right: 16)
        row.translatesAutoresizingMaskIntoConstraints = false
        textLabel.preferredMaxLayoutWidth = Self.width - 20 - 16 - 14 * 2 - 26 - 30

        capsule.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: capsule.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: capsule.trailingAnchor),
            row.topAnchor.constraint(equalTo: capsule.topAnchor),
            row.bottomAnchor.constraint(equalTo: capsule.bottomAnchor),
            row.widthAnchor.constraint(equalToConstant: Self.width),
            column.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 14),
            column.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -14),
        ])
        contentView = capsuleBackground(around: capsule, radius: Self.radius)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func present(agent: String, text: String, backlog: Int) {
        textLabel.stringValue = text
        self.agent = agent
        setBacklog(backlog)
        orderFrontRegardless()
    }

    func setBacklog(_ backlog: Int) {
        detailLabel.stringValue = backlog > 0 ? "\(agent) · +\(backlog) more" : agent
        layoutAndPlace()
    }

    private func layoutAndPlace() {
        row.layoutSubtreeIfNeeded()
        let size = row.fittingSize
        // The screen the user is working on, chosen as the capsule opens.
        guard let screen = (isVisible ? self.screen : nil) ?? NSScreen.active else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(x: visible.midX - size.width / 2,
                             y: visible.maxY - Self.margin - size.height)
        setFrame(NSRect(origin: origin, size: size), display: true)
        capsule.frame = NSRect(origin: .zero, size: size)
    }
}

// Takes every click, including the first into an inactive app.
private final class StopView: NSView {
    var onClick: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}
