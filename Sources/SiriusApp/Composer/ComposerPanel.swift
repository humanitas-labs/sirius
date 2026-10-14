import AppKit
import SiriusCore
import SwiftUI

// The composer, after its Figma design: a 652 × 196 dark panel (now
// 648 × 184) with a 32pt radius at the bottom centre of the screen, the text
// at the top left with a light-blue caret, and at the bottom right the
// current agent's mark and the ⌘ pill that sends. The mark is the agent's
// logo.
@MainActor
final class ComposerPanel: NSPanel {
    var onSend: (() -> Void)?
    var onNextAgent: (() -> Void)?
    var onCancel: (() -> Void)?
    var onAttach: (([URL]) -> Void)?
    var onRemoveAttachment: ((URL) -> Void)?
    // The vertical padding scales with the text, 16/18 since it went to 16,
    // as the old padding was a bit much at the new size: text top 31 → 28,
    // the pill 28.78 → 26 off the bottom, the tiles 27 → 24. The box stays
    // 196 tall, the text area taking the room. Then, as there was still a
    // little too much vertical padding: 3 off the top and 3 off the bottom,
    // the text 28 → 25, the tiles 24 → 21, the pill 26 → 23 off the
    // bottom, and the box 196 → 190. Then the sides 27 → 24.
    // Then a touch tighter again: 20 at the sides, 22 at the top, 20 at
    // the bottom, the tiles 21 → 18, and the panel 190 → 184.
    static let size = NSSize(width: 648, height: 184)
    private static let sideInset: CGFloat = 20
    private static let textTopInset: CGFloat = 22
    private static let caretRoom: CGFloat = 2
    private static let pillBottomInset: CGFloat = 20
    private static let pillHeight: CGFloat = 30.56
    // From the text's bottom to the pill's top.
    private static let textBottomGap: CGFloat = 12
    // Bottom edge of the panel above the Dock, or the screen's bottom edge
    // when it is hidden. The design had 113pt, which sat too high. The toast
    // opens at the same height, so both open in the same area.
    static let bottomGap: CGFloat = 40

    let textView = ComposerTextView()
    private let agentButton = NSButton()
    // A bolt left of the logo when the agent runs in fast mode, as the
    // ChatGPT app marks Fast.
    // TODO(andrew): size, colour and offset are a first pass.
    private let fastBadge = NSImageView()
    private let sendButton = NSButton()
    // Attached files as thumbnails above the text, the panel's bottom edge
    // fixed. With
    // any, the panel is taller by tilesAdded (fitHeight).
    private let tiles = NSStackView()
    private var textTop: NSLayoutConstraint?
    // The dictation waves at the bottom centre, live while fn is held with
    // the composer open, in place of the pill: the pill's waves, inside the
    // composer. Hidden otherwise, fading in as the hold starts and out once
    // it is transcribed, so there are no idle waves; only fn brings them.
    // 51 × 20, centred on the panel and on the send pill's centre line,
    // 38.28 above the bottom edge, the bars centred in their view (for a
    // while they stood on the pill's bottom edge). At full height they reach 48.28 above it, and
    // the text ends 65.56 above it. The fast bolt, the leftmost of the
    // agent's line, starts about 160 right of the waves, so nothing moves.
    // DictationService drives them.
    let waves = DictationWavesModel()
    private static let tilesTop: CGFloat = 18
    private static let tilesGap: CGFloat = 10
    private static var tilesHeight: CGFloat { AttachmentTile.side + tilesGap }
    // How much taller the panel is with tiles. It was the tile row, 74,
    // which left the text the empty box's room under them, 5.5 lines of
    // 18; the aim is less added space, not hugging the content. 40 would
    // leave 3.86
    // lines, the fourth clipped; 42 leaves four whole lines, 72.44 from
    // the tiles' gap to 12 above the pill, and longer text scrolls.
    private static let tilesAdded: CGFloat = 42
    // The panel grows upward with the text, its bottom edge fixed: from the
    // box's own room (about 5½ lines) to 12 lines, and never past 60% of
    // the screen's visible height (the text used to stop at about 6 lines).
    // Past that it scrolls.
    private static let maxLines: CGFloat = 12
    private static let maxScreenShare: CGFloat = 0.6
    private static let lineHeight = NSLayoutManager().defaultLineHeight(for: Palette.body)
    private let scroll = ComposerScrollView()

    init() {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        // Sirius activates while the composer is open: dictation and the
        // selection only work in the active app. The controller hands focus
        // back to the user's app on close.
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        NotificationCenter.default.addObserver(self, selector: #selector(showCaret),
                                               name: NSApplication.didBecomeActiveNotification, object: nil)
        // The active screen follows the user's app and the displays'
        // settings; warm for it as it changes, not on the summon.
        NotificationCenter.default.addObserver(self, selector: #selector(warmIfMoved),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(warmIfMoved),
                                                          name: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(warmIfMoved),
                                                          name: NSWorkspace.activeSpaceDidChangeNotification,
                                                          object: nil)
        isMovable = false
        applyComposerWindowShadow(to: self)

        let background = ComposerBackground(frame: NSRect(origin: .zero, size: Self.size))
        background.onDrop = { [weak self] urls in self?.onAttach?(urls) }
        contentView = background

        // The text: caret at (sideInset, textTopInset) from the top left, 22pt tall.
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = Palette.body
        textView.textColor = Palette.text
        textView.insertionPointColor = Palette.caret
        // The caret takes its size from the typing attributes; set them so
        // the empty field's caret matches the one beside typed text.
        textView.typingAttributes = [.font: Palette.body, .foregroundColor: Palette.text]
        textView.textContainerInset = .zero
        // Room for the caret at the start of a line: AppKit centres it on its
        // position, so at x = 0 the view's edge clipped its left half and it
        // drew thinner until the first character. The scroll view sits
        // caretRoom further left, so the text stays at sideInset.
        textView.textContainer?.lineFragmentPadding = Self.caretRoom
        // Smart quotes and dashes follow the user's System Settings (Keyboard >
        // Text Input), as in any Mac text field.
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.isSelectable = true
        textView.isEditable = true
        textView.selectedTextAttributes = [.backgroundColor: Palette.selection]
        textView.onSend = { [weak self] in self?.onSend?() }
        textView.onNextAgent = { [weak self] in self?.onNextAgent?() }
        textView.onCancel = { [weak self] in self?.onCancel?() }
        textView.onPasteFiles = { [weak self] urls in self?.onAttach?(urls) }
        // ⌫ or ⌘⌫ with the caret at the start takes off the last tile,
        // through the same path as its ×.
        textView.onRemoveLastAttachment = { [weak self] in
            guard let self, let last = tiles.arrangedSubviews.compactMap({ ($0 as? AttachmentTile)?.url }).last
            else { return false }
            onRemoveAttachment?(last)
            return true
        }
        scroll.documentView = textView
        background.addSubview(scroll)
        NotificationCenter.default.addObserver(self, selector: #selector(textChanged),
                                               name: NSText.didChangeNotification, object: textView)

        // TODO(andrew): not in the Figma design; tiles 8 apart, on the text's
        // left edge.
        tiles.orientation = .horizontal
        tiles.spacing = 8
        tiles.alignment = .top
        tiles.isHidden = true
        tiles.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(tiles)

        // The agent's icon: 16 × 16, 21.5pt left of the pill.
        agentButton.isBordered = false
        agentButton.imagePosition = .imageOnly
        agentButton.imageScaling = .scaleProportionallyUpOrDown
        agentButton.target = self
        agentButton.action = #selector(nextAgent)
        agentButton.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(agentButton)
        fastBadge.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Fast")
        fastBadge.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        fastBadge.contentTintColor = NSColor(srgbRed: 0xE2 / 255, green: 0xE3 / 255, blue: 0xE4 / 255, alpha: 1)
        fastBadge.isHidden = true
        fastBadge.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(fastBadge)

        // The pill: 58 × 30.5, radius 11, the ⌘ glyph 11pt in from its left.
        sendButton.isBordered = false
        sendButton.title = ""
        sendButton.wantsLayer = true
        sendButton.layer?.backgroundColor = Palette.pill.cgColor
        sendButton.layer?.cornerRadius = 11
        sendButton.layer?.cornerCurve = .continuous
        sendButton.target = self
        sendButton.action = #selector(send)
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        // Return sends, so the pill shows ↩ (was the design's ⌘).
        let glyph = NSImageView(image: NSImage(systemSymbolName: "return", accessibilityDescription: "Send") ?? NSImage())
        glyph.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        glyph.contentTintColor = Palette.glyph
        glyph.translatesAutoresizingMaskIntoConstraints = false
        sendButton.addSubview(glyph)
        sendButton.setAccessibilityLabel("Send")
        background.addSubview(sendButton)

        let wavesView = ClickThroughHostingView(rootView: DictationWaves(model: waves, hidesAtRest: true))
        wavesView.sizingOptions = []
        wavesView.setAccessibilityElement(false)
        wavesView.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(wavesView)

        let textTop = scroll.topAnchor.constraint(equalTo: background.topAnchor, constant: Self.textTopInset)
        self.textTop = textTop
        NSLayoutConstraint.activate([
            textTop,
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: Self.sideInset - Self.caretRoom),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -Self.sideInset + Self.caretRoom),
            scroll.bottomAnchor.constraint(equalTo: sendButton.topAnchor, constant: -Self.textBottomGap),

            tiles.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: Self.sideInset),
            tiles.trailingAnchor.constraint(lessThanOrEqualTo: background.trailingAnchor, constant: -Self.sideInset),
            tiles.topAnchor.constraint(equalTo: background.topAnchor, constant: Self.tilesTop),
            tiles.heightAnchor.constraint(equalToConstant: AttachmentTile.side),

            sendButton.widthAnchor.constraint(equalToConstant: 58.07),
            sendButton.heightAnchor.constraint(equalToConstant: Self.pillHeight),
            sendButton.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -(Self.sideInset - 1.53)),
            sendButton.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -Self.pillBottomInset),
            glyph.centerXAnchor.constraint(equalTo: sendButton.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: sendButton.centerYAnchor),

            agentButton.widthAnchor.constraint(equalToConstant: 20),
            agentButton.heightAnchor.constraint(equalToConstant: 20),
            agentButton.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -19.46),
            agentButton.centerYAnchor.constraint(equalTo: sendButton.centerYAnchor),
            fastBadge.trailingAnchor.constraint(equalTo: agentButton.leadingAnchor, constant: -6),
            fastBadge.centerYAnchor.constraint(equalTo: agentButton.centerYAnchor),

            wavesView.widthAnchor.constraint(equalToConstant: DictationWaves.size.width),
            wavesView.heightAnchor.constraint(equalToConstant: DictationWaves.size.height),
            wavesView.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            wavesView.centerYAnchor.constraint(equalTo: sendButton.centerYAnchor),
        ])
    }

    // Key, so it takes typing; never main, so it never becomes the user's
    // document window.
    override var canBecomeKey: Bool { true }

    // The caret showed only once typing began: the
    // panel becomes key before NSApp.activate() has taken effect, and the
    // text view did not restart its caret when the app turned active. Both
    // moments restart it now.
    override func becomeKey() {
        super.becomeKey()
        showCaret()
    }

    @objc private func showCaret() {
        guard isKeyWindow, firstResponder === textView else { return }
        textView.updateInsertionPointStateAndRestartTimer(true)
    }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    func setAgent(name: String, mark: NSImage?, fast: Bool = false) {
        agentButton.image = mark
        fastBadge.isHidden = !fast
        let shown = fast ? "\(name), fast" : name
        agentButton.toolTip = "\(shown) (⌘/ for the next agent)"
        agentButton.setAccessibilityLabel(shown)
    }

    func setAttachments(_ urls: [URL]) {
        let shown = tiles.arrangedSubviews.compactMap { ($0 as? AttachmentTile)?.url }
        guard shown != urls else { return }
        for view in tiles.arrangedSubviews { view.removeFromSuperview() }
        for url in urls {
            let tile = AttachmentTile(url: url)
            tile.onRemove = { [weak self] in self?.onRemoveAttachment?(url) }
            tiles.addArrangedSubview(tile)
        }
        let grow = urls.isEmpty != tiles.isHidden
        tiles.isHidden = urls.isEmpty
        // The text moves down to 10 below the tiles (.capture-files' margin).
        textTop?.constant = urls.isEmpty ? Self.textTopInset : Self.tilesTop + Self.tilesHeight
        if grow { fitHeight() }
    }

    // 184 without tiles, 226 with, taller with the text up to maxLines
    // (capped by the screen); the bottom edge stays.
    func fitHeight() {
        let base = Self.size.height + (tiles.isHidden ? 0 : Self.tilesAdded)
        let room = base - (textTop?.constant ?? Self.textTopInset) - Self.pillBottomInset - Self.pillHeight - Self.textBottomGap
        var height = base + min(max(textHeight - room, 0), max(Self.maxLines * Self.lineHeight - room, 0))
        if let screen = NSScreen.active ?? screen {
            height = min(height, (screen.visibleFrame.height * Self.maxScreenShare).rounded(.down))
        }
        height = max(height, base).rounded(.up)
        guard height != frame.height else { return }
        var rect = frame
        rect.size.height = height
        setFrame(rect, display: true)
        contentView?.layoutSubtreeIfNeeded()
        if isVisible, closing == nil {
            NotificationCenter.default.post(name: .composerFrame, object: NSValue(rect: frame))
        }
    }

    // The laid-out text's height, the empty line after a final return included.
    private var textHeight: CGFloat {
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return 0 }
        layout.ensureLayout(for: container)
        return layout.usedRect(for: container).height
    }

    // Grows first, then keeps the caret in view.
    @objc private func textChanged() {
        fitHeight()
        if textView.frame.height <= scroll.contentView.bounds.height {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    func present() {
        closing?.invalidate()
        closing = nil
        place()
        fitHeight()
        if let screen = NSScreen.active, warmedFor != Self.key(screen) { prewarm() }
        NSApp.activate()
        makeKeyAndOrderFront(nil)
        // Resigned first, so the text view takes focus afresh even when it
        // kept it from the last open, and its caret starts blinking.
        makeFirstResponder(nil)
        makeFirstResponder(textView)
        // A quicker open, same Spatial spring shape: pace 0.8
        // settles in 0.3 s against 0.4 s at pace 1 (settlingDuration rounds
        // to 0.1 s steps).
        SpatialMotion.open(contentView, pace: 0.8)
        NotificationCenter.default.post(name: .composerFrame, object: NSValue(rect: frame))
    }

    // Springs shut (SpatialMotion), then leaves the screen; `done` runs once
    // it is gone.
    func dismiss(_ done: @escaping () -> Void) {
        guard isVisible, closing == nil else { return }
        NotificationCenter.default.post(name: .composerFrame, object: nil)
        closing = SpatialMotion.close(contentView) { [weak self] in
            self?.closing = nil
            self?.orderOut(nil)
            done()
        }
    }

    private var closing: Timer?

    // On screen and not springing shut.
    var isOpen: Bool { isVisible && closing == nil }

    // Dictated text at the caret, replacing any selection, with one space
    // before it when it would run on from the word before
    // (DictationSpacing). Through insertText, so it is one undo step and
    // takes the typing attributes.
    func insert(_ text: String) {
        let range = textView.selectedRange()
        let string = textView.string as NSString
        var previous: Character?
        if range.location > 0, range.location <= string.length {
            let before = string.rangeOfComposedCharacterSequence(at: range.location - 1)
            previous = Character(string.substring(with: before))
        }
        let spaced = DictationSpacing.spaced(text, after: previous)
        guard !spaced.isEmpty else { return }
        textView.insertText(spaced, replacementRange: range)
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    // Draws the panel once, invisibly, where it will open: building its
    // layers took 21 ms and dropped the first frame of the first open
    // (Instruments, 2026.10.10). Drawn off every screen, as it was, the
    // first real open still paid for the display's backing store mid-spring,
    // and so did the first open on another screen (#6: "it jitters on the
    // first open after launch … and maybe when the active screen changes").
    // So it is drawn on the screen it opens on: at launch, and again before
    // an open on a screen it was not drawn on, which waits for it (about
    // 20 ms, once per screen).
    func prewarm() {
        place()
        alphaValue = 0
        orderFrontRegardless()
        display()
        contentView?.layer?.displayIfNeeded()
        CATransaction.flush()
        orderOut(nil)
        alphaValue = 1
        warmedFor = NSScreen.active.map(Self.key)
    }

    // Warms for the active screen when it is not the one last drawn on,
    // while the panel is away. A summon on a screen not yet warmed (the
    // mouse moved there, no app switched) still warms in present().
    @objc private func warmIfMoved() {
        guard !isVisible, let screen = NSScreen.active, warmedFor != Self.key(screen) else { return }
        prewarm()
    }

    // The screen the panel was last drawn on, and its scale, which a change
    // of resolution or display settings can change.
    private var warmedFor: String?

    private static func key(_ screen: NSScreen) -> String {
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
        return "\(id)@\(screen.backingScaleFactor)"
    }

    @objc private func nextAgent() { onNextAgent?() }
    @objc private func send() { onSend?() }

    // Bottom centre of the screen the user is working on, bottomGap above
    // the Dock: the toast's screen and spot (NSScreen.active).
    private func place() {
        guard let screen = NSScreen.active else { return }
        let visible = screen.visibleFrame
        setFrameOrigin(NSPoint(x: (visible.midX - Self.size.width / 2).rounded(), y: visible.minY + Self.bottomGap))
    }
}

extension Notification.Name {
    // The open composer's frame, or nil as it closes, so the toast can stand
    // above it (ToastPanel.avoid).
    static let composerFrame = Notification.Name("SiriusComposerFrame")
}

enum Palette {
    // The composer's text: 15.4, down from 18, which read a touch big, and
    // then 16. The toast no longer matches it: it took its own 15 with the
    // notification-banner look.
    static let body = NSFont.systemFont(ofSize: 15.4)
    static let background = NSColor(srgbRed: 0x0E / 255, green: 0x0E / 255, blue: 0x0F / 255, alpha: 1)
    // The panel over a blur, with some of what is behind it showing: the
    // old colour with some glass in it. Near-black #040302, so the hue is
    // the blur's own. At 82% it read about #0B111A over a blue wallpaper;
    // at 76%, a touch more see-through with the same hue, about #0D1622.
    // Then, a touch dark still, the fill raised to #0A0A0B, about #121B29.
    // Over a light teal wallpaper 76% read #18342F, plainly green (the blur
    // measured about (69, 185, 162)), so the fill went back up to 88%: about
    // #111F1D there and #0E131A over the blue one. A fill solved to land on
    // #0E0E0F (#0B0702 at 90%) was tried; the darker one read better. The
    // colour moves with what is behind it.
    static let glassFill = NSColor(srgbRed: 0x0A / 255, green: 0x0A / 255, blue: 0x0B / 255, alpha: 0.88)
    static let border = NSColor(srgbRed: 0x17 / 255, green: 0x17 / 255, blue: 0x19 / 255, alpha: 1)
    static let caret = NSColor(srgbRed: 0xB5 / 255, green: 0xD1 / 255, blue: 0xFF / 255, alpha: 1)
    static let pill = NSColor(srgbRed: 0x18 / 255, green: 0x1B / 255, blue: 0x1F / 255, alpha: 1)
    // The design's icon colour; it shows no typed text.
    static let text = NSColor(srgbRed: 0xF9 / 255, green: 0xF7 / 255, blue: 0xF5 / 255, alpha: 1)
    static let secondary = NSColor(white: 1, alpha: 0.45)
    // The send pill's glyph, the design's #E2E3E4.
    static let glyph = NSColor(srgbRed: 0xE2 / 255, green: 0xE3 / 255, blue: 0xE4 / 255, alpha: 1)
    // TODO(andrew): not in the design; the caret's blue, dimmed.
    static let selection = NSColor(srgbRed: 0xB5 / 255, green: 0xD1 / 255, blue: 0xFF / 255, alpha: 0.3)
}

// The waves take no clicks or drops: those reach the panel's body beneath.
private final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// The panel's body: fill, hairline border, radius 32. Takes dropped files.
private final class ComposerBackground: NSView {
    var onDrop: (([URL]) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // A blur, not Liquid Glass: NSGlassEffectView changes its surface
        // when the window loses focus, with no public way to hold it, and the
        // surface must not change. The HUD blur is held active, under the panel's colour
        // (Palette.glassFill). The border draws above.
        let blur = NSVisualEffectView(frame: bounds)
        blur.appearance = NSAppearance(named: .darkAqua)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]
        addSubview(blur)
        let fill = NSView(frame: bounds)
        fill.wantsLayer = true
        fill.layer?.backgroundColor = Palette.glassFill.cgColor
        fill.autoresizingMask = [.width, .height]
        addSubview(fill)
        layer?.borderColor = Palette.border.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 32
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
}

// The text's scroll view. Past the panel's tallest it scrolls, with a thin
// overlay scroller, and the text fades out over the top or bottom fade
// points wherever more of it lies that way: a mask, not a coloured
// gradient, since the panel is glass.
final class ComposerScrollView: NSScrollView {
    static let fade: CGFloat = 20
    private let fadeMask = CAGradientLayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerKnobStyle = .light
        super.scrollerStyle = .overlay
        layer?.mask = fadeMask
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(updateFade),
                                               name: NSView.boundsDidChangeNotification, object: contentView)
    }

    required init?(coder: NSCoder) { nil }

    // Overlay even with "Always" show scroll bars set.
    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
    }

    override var documentView: NSView? {
        didSet {
            documentView?.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(updateFade),
                                                   name: NSView.frameDidChangeNotification, object: documentView)
        }
    }

    override func layout() {
        super.layout()
        updateFade()
    }

    @objc private func updateFade() {
        guard bounds.height > 0 else { return }
        let visible = contentView.bounds
        let above = visible.minY > 0.5
        let below = (documentView?.frame.maxY ?? 0) - visible.maxY > 0.5
        let share = min(Self.fade / bounds.height, 0.5)
        let clear = NSColor.clear.cgColor, opaque = NSColor.black.cgColor
        // The layer's y runs up unless the view is flipped.
        let (start, end) = (above ? clear : opaque, below ? clear : opaque)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fadeMask.frame = bounds
        fadeMask.colors = isFlipped ? [start, opaque, opaque, end] : [end, opaque, opaque, start]
        fadeMask.locations = [0, NSNumber(value: Double(share)), NSNumber(value: Double(1 - share)), 1]
        CATransaction.commit()
    }
}

// Return sends and Shift-Return adds a line, as in chat apps; ⌘Return
// sends too. ⌘/ or Shift-Tab (as in Claude Code) switches to the next agent;
// Escape closes. A paste of
// files or an image attaches them instead of inserting text. ⌫ or ⌘⌫ with
// the caret at the start, nothing selected, removes the last attachment, as
// in chat apps; with text before the caret they keep their usual meaning.
final class ComposerTextView: NSTextView {
    var onSend: (() -> Void)?
    var onNextAgent: (() -> Void)?
    var onCancel: (() -> Void)?
    var onPasteFiles: (([URL]) -> Void)?
    // Removes the last attachment; false when there is none.
    var onRemoveLastAttachment: (() -> Bool)?

    private var caretAtStart: Bool {
        let range = selectedRange()
        return range.location == 0 && range.length == 0 && !hasMarkedText()
    }

    override func deleteBackward(_ sender: Any?) {
        if caretAtStart, onRemoveLastAttachment?() == true { return }
        super.deleteBackward(sender)
    }

    override func deleteToBeginningOfLine(_ sender: Any?) {
        if caretAtStart, onRemoveLastAttachment?() == true { return }
        super.deleteToBeginningOfLine(sender)
    }

    override func keyDown(with event: NSEvent) {
        ComposerSignposts.firstKey()
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch (event.keyCode, flags) {
        case (36, []), (36, [.command]), (76, []), (76, [.command]):
            onSend?()
        case (44, [.command]), (48, [.shift]):
            onNextAgent?()
        default:
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 44, flags == [.command] {
            onNextAgent?()
            return true
        }
        // Sirius has no Edit menu (it lives in the menu bar), so the standard
        // editing shortcuts are routed here.
        let editing: [String: Selector] = [
            "a": #selector(selectAll(_:)), "c": #selector(copy(_:)), "v": #selector(paste(_:)),
            "x": #selector(cut(_:)), "z": Selector(("undo:")),
        ]
        if flags == [.command], let key = event.charactersIgnoringModifiers, let action = editing[key] {
            return NSApp.sendAction(action, to: nil, from: self)
        }
        if flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "z" {
            return NSApp.sendAction(Selector(("redo:")), to: nil, from: self)
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    // Typing, and dictation, keep the caret clear of the scroll view's fades.
    override func scrollRangeToVisible(_ range: NSRange) {
        super.scrollRangeToVisible(range)
        guard let layout = layoutManager, let container = textContainer else { return }
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        if range.location >= layout.numberOfGlyphs, layout.extraLineFragmentTextContainer != nil {
            rect = layout.extraLineFragmentRect
        }
        rect.origin.y += textContainerOrigin.y
        scrollToVisible(rect.insetBy(dx: 0, dy: -ComposerScrollView.fade))
    }

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            onPasteFiles?(urls)
            return
        }
        if pasteboard.string(forType: .string) == nil, let image = NSImage(pasteboard: pasteboard),
           let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("sirius-paste-\(UUID().uuidString.prefix(8)).png")
            if (try? png.write(to: url)) != nil {
                onPasteFiles?([url])
                return
            }
        }
        pasteAsPlainText(sender)
    }
}
