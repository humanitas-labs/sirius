import AppKit

// The toast, after the iPhone Maps navigation banner: a dark Liquid Glass
// capsule at the bottom centre, a large glyph on the left, the message in
// bold white, in one style: no second line; the logo says who sent it. No
// grabber: that is the iPhone's, not the Mac's.
// The glyph is the sending agent's logo in its own colours (the orange
// Claude mark, so agents are told apart at a glance); the sparkle when the
// agent has none (dev).
// The capsule grows with the text up to four lines, the banner's limit; past
// that the last line ends in an ellipsis. The agents are told to keep under
// 240 characters (packaging/agent/instructions.md), which fits.
// Motion follows the reference ack bubble's: it springs open and shut as
// the composer does (SpatialMotion), and a toast arriving while one shows
// swaps in place: the old line blurs, fades and drops in 150 ms, a 70 ms
// beat, then the new one rises out of the blur over 310 ms while the capsule
// eases to its height. Queued toasts take their turn through the same swap.
// TODO(andrew): the colour effect, the final metrics, and whether to show
// how many toasts are waiting (the "+N more" line went with the agent line).
@MainActor
final class ToastPanel: NSPanel {
    // The × or a swipe up dismisses.
    var onClick: (() -> Void)?
    // The pointer resting on the toast holds it.
    var onHover: ((Bool) -> Void)?

    // After the macOS notification banner, the best reference for the
    // design and sizing (measured from an @2x capture): 344 wide, 13pt text,
    // a 34pt avatar 12 in, a corner of about 20. Its proportions and text
    // style, scaled by 15/13: 13pt read too small, 14 still a bit hard to
    // read. A 38 box for the one-line height, corner
    // 22. No title line. All the text shows. The card fits the text up to
    // 520: 560 at 14pt got "a touch too wide"; 520 keeps that cap's 480 at
    // 14pt in proportion, about 63 characters a line. Then 490 at 14.6pt, a
    // touch narrower.
    // Then the reference ack bubble's, after the two side by side: 540 at
    // most. The corner stays 22: the bubble's 20 felt slightly too little.
    static let width: CGFloat = 540
    static let radius: CGFloat = 22
    // The one-line height before padding: the text's line, so one line is
    // the bubble's 52 tall.
    private static let glyphSize: CGFloat = CapsuleView.lineHeight
    // Gap above the Dock, or the screen's bottom edge when the Dock is
    // hidden: the composer's, so both open in the same place (was 24).
    private static let margin = ComposerPanel.bottomGap

    // The reference bubble's swap: out, a gap, then in.
    private static var swapOut: TimeInterval { 0.15 * SpatialMotion.timeScale }
    private static var swapGap: TimeInterval { 0.07 * SpatialMotion.timeScale }
    private static let swapOutDrop: CGFloat = 7
    private static let swapInRise: CGFloat = 4
    // Siri's swap blurs the line out and back in, as the reference bubble's
    // does (blur(6px)).
    private static let swapBlur: CGFloat = 6

    private let capsule = CapsuleView(maxWidth: ToastPanel.width, glyphSize: ToastPanel.glyphSize)
    private let background: NSView
    // Layer-backed, so the grow and shrink scale the glass and the text as one.
    private let root = NSView()
    private var closing: Timer?
    private var swapping: DispatchWorkItem?
    private var resize: (from: NSSize, to: NSSize, start: CFTimeInterval)?
    private var link: CADisplayLink?
    // The toast stands above an open composer, as the reference ack bubble
    // lifts over its composer: its bottom 12 above the composer's top,
    // easing up and back down on the in curve over 310 ms.
    private static let clearance: CGFloat = 12
    private var composerFrame: NSRect?
    // And above the dictation pill, the same way.
    private var pillFrame: NSRect?
    private var bottom: CGFloat?
    private var lift: (from: CGFloat, to: CGFloat, start: CFTimeInterval)?
    private var liftLink: CADisplayLink?
    // The hover × (ToastClose): shown while the pointer is on the toast or on
    // it, hidden a beat after it leaves both, so crossing from one to the
    // other does not flicker it.
    private let close = ToastClose()
    private var overToast = false
    private var overClose = false
    private var hideClose: DispatchWorkItem?
    // The colour on arrival, in the border (SplashRing), over the card. Only
    // when the toast opens, not when a later one swaps in while it is up.
    private let ring = SplashRing(radius: ToastPanel.radius)

    init() {
        background = toastCard(around: capsule, radius: Self.radius)
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 80),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        // Floats over other apps without taking focus, on every Space and
        // beside full-screen windows.
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
        // Light, as the composer's, so macOS draws no bright rim of its own;
        // the card draws its faint edge itself and is held dark (toastCard).
        appearance = NSAppearance(named: .aqua)

        capsule.onClick = { [weak self] in self?.onClick?() }
        capsule.onHover = { [weak self] in
            self?.overToast = $0
            self?.hoverChanged()
        }
        close.onClick = { [weak self] in self?.onClick?() }
        close.onHover = { [weak self] in
            self?.overClose = $0
            self?.hoverChanged()
        }
        background.autoresizingMask = []
        root.wantsLayer = true
        root.addSubview(background)
        root.addSubview(ring.view)
        contentView = root
        NotificationCenter.default.addObserver(forName: .composerFrame, object: nil, queue: .main) { [weak self] note in
            let frame = (note.object as? NSValue)?.rectValue
            MainActor.assumeIsolated { self?.avoid(frame) }
        }
        NotificationCenter.default.addObserver(forName: .dictationPillFrame, object: nil, queue: .main) { [weak self] note in
            let frame = (note.object as? NSValue)?.rectValue
            MainActor.assumeIsolated { self?.avoid(frame, pill: true) }
        }
    }

    // Moves the toast above the composer at `frame`, or back down to its
    // place over the Dock when the composer closes (nil); the dictation
    // pill's with `pill`. Each clears only its own.
    func avoid(_ frame: NSRect?, pill: Bool = false) {
        if pill { pillFrame = frame } else { composerFrame = frame }
        guard isVisible, closing == nil, let screen, let from = bottom else { return }
        let to = restingBottom(on: screen)
        guard abs(to - from) >= 1 else { return }
        liftLink?.invalidate()
        lift = (from, to, CACurrentMediaTime())
        let link = root.displayLink(target: self, selector: #selector(stepLift(_:)))
        link.preferredFrameRateRange = SpatialMotion.frameRate
        link.add(to: .main, forMode: .common)
        liftLink = link
    }

    @objc private func stepLift(_ link: CADisplayLink) {
        guard let lift else { return link.invalidate() }
        let t = (CACurrentMediaTime() - lift.start) / SpatialMotion.inDuration
        bottom = lift.from + (lift.to - lift.from) * SpatialMotion.inProgress(t)
        place(size: frame.size)
        if t >= 1 {
            link.invalidate()
            liftLink = nil
            self.lift = nil
        }
    }

    // Over the Dock, or 12 above the composer or the pill, the higher,
    // when either is up on this screen.
    private func restingBottom(on screen: NSScreen) -> CGFloat {
        var resting = screen.visibleFrame.minY + Self.margin
        for frame in [composerFrame, pillFrame].compactMap({ $0 }) where screen.frame.intersects(frame) {
            resting = max(resting, frame.maxY + Self.clearance)
        }
        return resting
    }

    private func hoverChanged() {
        let over = overToast || overClose
        onHover?(over)
        hideClose?.cancel()
        hideClose = nil
        if over {
            guard isVisible, closing == nil else { return }
            placeClose()
            close.show(above: self)
        } else {
            let hide = DispatchWorkItem { [weak self] in self?.close.hide() }
            hideClose = hide
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: hide)
        }
    }

    // On the card's top-left corner, wherever the card is now.
    private func placeClose() {
        let card = background.frame.offsetBy(dx: frame.minX, dy: frame.minY)
        close.place(on: card)
    }

    // Never key: a toast must not take keyboard focus from the user's app.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // Shows the toast: grown in when none is up, swapped in place when one is.
    func present(agent: String, mark: NSImage?, text: String) {
        let glyph = Self.glyph(agent: agent, mark: mark)
        swapping?.cancel()
        swapping = nil
        guard isVisible, closing == nil else {
            closing?.invalidate()
            closing = nil
            stopResize()
            liftLink?.invalidate()
            liftLink = nil
            lift = nil
            bottom = nil
            capsule.resetContent()
            capsule.set(glyph: glyph, text: text, agent: agent)
            let size = capsule.fittingSize()
            place(size: size)
            setCapsuleSize(size)
            orderFrontRegardless()
            SpatialMotion.open(root, about: background.frame)
            ring.splash()
            return
        }
        capsule.animateContent(opacity: 0, offset: -Self.swapOutDrop, blur: Self.swapBlur, duration: Self.swapOut,
                               timing: SpatialMotion.outCurve)
        let swap = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.swapping = nil
            let from = self.background.frame.size
            self.capsule.set(glyph: glyph, text: text, agent: agent)
            self.resize(from: from, to: self.capsule.fittingSize())
            self.capsule.riseIn(from: -Self.swapInRise, blur: Self.swapBlur)
        }
        swapping = swap
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.swapOut + Self.swapGap, execute: swap)
    }

    // Shrinks out, then leaves the screen.
    func dismiss() {
        guard isVisible, closing == nil else { return }
        swapping?.cancel()
        swapping = nil
        hideClose?.cancel()
        close.hide(animated: false)
        overClose = false
        closing = SpatialMotion.close(root, about: background.frame) { [weak self] in
            guard let self else { return }
            self.closing = nil
            self.stopResize()
            self.orderOut(nil)
        }
    }

    private static func glyph(agent: String, mark: NSImage?) -> NSImage? {
        if let mark, let logo = mark.copy() as? NSImage {
            // 24, down from 30, which was a touch big relative to the text.
            logo.size = NSSize(width: CapsuleView.markSize, height: CapsuleView.markSize)
            // One light colour, as the bubble's mark, not the logo's own.
            logo.isTemplate = true
            logo.accessibilityDescription = agent
            return logo
        }
        return NSImage(systemSymbolName: "sparkle", accessibilityDescription: agent)
    }

    // The capsule eases from one size to the next on the in curve, its
    // bottom edge fixed and its width about the centre. The window takes the
    // larger of the two for the length of it, so the capsule never outgrows
    // it, then fits again.
    private func resize(from: NSSize, to: NSSize) {
        stopResize()
        guard abs(to.height - from.height) >= 1 || abs(to.width - from.width) >= 1 else { return setCapsuleSize(to) }
        place(size: NSSize(width: max(from.width, to.width), height: max(from.height, to.height)))
        setCapsuleSize(from)
        resize = (from, to, CACurrentMediaTime())
        let link = root.displayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = SpatialMotion.frameRate
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let resize else { return stopResize() }
        let t = (CACurrentMediaTime() - resize.start) / SpatialMotion.inDuration
        let progress = SpatialMotion.inProgress(t)
        setCapsuleSize(NSSize(width: resize.from.width + (resize.to.width - resize.from.width) * progress,
                              height: resize.from.height + (resize.to.height - resize.from.height) * progress))
        if t >= 1 {
            stopResize()
            place(size: resize.to)
            setCapsuleSize(resize.to)
        }
    }

    private func stopResize() {
        link?.invalidate()
        link = nil
        resize = nil
    }

    // Centred across the window, which is the wider of the two sizes
    // through a resize.
    private func setCapsuleSize(_ size: NSSize) {
        let x = ((root.bounds.width - size.width) / 2).rounded()
        background.frame = NSRect(x: max(0, x), y: 0, width: size.width, height: size.height)
        capsule.needsLayout = true
        ring.setFrame(background.frame)
        invalidateShadow()
        if close.isShown { placeClose() }
    }

    // Bottom centre of the screen the user is working on (NSScreen.active),
    // above the Dock, clear of Notification Center's
    // corner where notify's banners appear. Chosen as the toast opens; a swap
    // or resize keeps it where it is.
    private func place(size: NSSize) {
        guard let screen = (isVisible && closing == nil ? self.screen : nil) ?? NSScreen.active else { return }
        let visible = screen.visibleFrame
        let y = bottom ?? restingBottom(on: screen)
        bottom = y
        let origin = NSPoint(x: (visible.midX - size.width / 2).rounded(), y: y)
        setFrame(NSRect(origin: origin, size: size), display: true)
        if close.isShown { placeClose() }
    }
}

// The card: a frosted blur under a near-black tint, after the macOS
// notification banner (it replaced Siri's navy answer card): fill #1F2121 at
// 70%, and a 0.5pt hairline in 15% white (measured: fill 31,33,33, rim 67 at
// 1px @2x). 88% hid the wallpaper to a faint cast and read too dark.
// On macOS 26 the banner itself is Liquid Glass in the dark appearance, so
// the card is that glass, untinted, to match the dark-mode banners exactly.
// The toast is never key, so the glass keeps one look. The
// glass alone came out far lighter than the banners: measured on screen
// (2026.10.10), Notification Center's cards sit at about half the
// wallpaper's brightness, in a neutral grey, while the bare glass barely
// darkened it and kept its colour. So a neutral dim lies inside the glass:
// #1A1A1A at 40%, then 55% and 68%, darker each time while keeping the
// glass, then the composer's own fill, #0A0A0B, at 85%, closer to the
// composer's colour. The glass behind is
// brighter than the composer's blur, so it takes a little less to match.
// The blur and tint below remain for macOS 14 and 15.
// Then the reference ack bubble on its glass, keeping a touch of this
// glass: its composer's surface, #111212, and a 1pt rim of 8% white. The
// bubble lays it at 70% over the HUD blur; the Liquid Glass here is
// brighter, so 80%.
// Then a little darker, halfway to the composer's surface (#0A0A0B at 88%):
// #0E0E0F, at 84% on the glass and 79% on the blur.
// Then more of the glass through it: the same fill at 72% on the glass and
// 68% on the blur. Over a white wallpaper, taking the glass as passing it
// through, the text still holds about 6.5:1.
// Then between the two: 78% on the glass and 74% on the blur. Over a white wallpaper, with #E8E9EA text, that is about 8:1.
private let toastSurface = NSColor(srgbRed: 0x0E / 255, green: 0x0E / 255, blue: 0x0F / 255, alpha: 1)
private let toastRim = NSColor(white: 1, alpha: 0.08)

// The glass adapts to what is behind it by default: a small card over a
// bright page turns to the light glass, and once the card is larger it stops
// adapting and keeps that, so the one toast panel, reused for every toast,
// stayed light over dark pages until Sirius restarted (the dim over the
// light glass reads #404041 on a #0B0B0B page, over the dark glass
// #18181A). There is no public switch; the private one is used when it is
// there, and the glass is left as it is when it is not.
@available(macOS 26, *)
@MainActor
private func holdDark(_ glass: NSGlassEffectView) {
    let off = 1
    guard glass.responds(to: NSSelectorFromString("set_adaptiveAppearance:")) else { return }
    glass.setValue(off, forKey: "_adaptiveAppearance")
}

@MainActor
func toastCard(around content: NSView, radius: CGFloat) -> NSView {
    content.frame = .zero
    content.autoresizingMask = [.width, .height]
    if #available(macOS 26, *) {
        let glass = NSGlassEffectView()
        glass.appearance = NSAppearance(named: .darkAqua)
        glass.style = .regular
        glass.cornerRadius = radius
        holdDark(glass)
        let body = NSView()
        let dim = NSView()
        dim.wantsLayer = true
        dim.layer?.backgroundColor = toastSurface.withAlphaComponent(0.78).cgColor
        dim.layer?.cornerRadius = radius
        dim.layer?.cornerCurve = .continuous
        dim.layer?.borderWidth = 1
        dim.layer?.borderColor = toastRim.cgColor
        dim.autoresizingMask = [.width, .height]
        dim.frame = .zero
        body.addSubview(dim)
        body.addSubview(content)
        glass.contentView = body
        return glass
    }
    let blur = NSVisualEffectView()
    blur.appearance = NSAppearance(named: .darkAqua)
    blur.material = .hudWindow
    blur.blendingMode = .behindWindow
    blur.state = .active
    blur.wantsLayer = true
    blur.layer?.cornerRadius = radius
    blur.layer?.cornerCurve = .continuous
    blur.layer?.masksToBounds = true
    let tint = NSView()
    tint.wantsLayer = true
    tint.layer?.backgroundColor = toastSurface.withAlphaComponent(0.74).cgColor
    tint.layer?.cornerRadius = radius
    tint.layer?.cornerCurve = .continuous
    tint.layer?.borderWidth = 1
    tint.layer?.borderColor = toastRim.cgColor
    tint.autoresizingMask = [.width, .height]
    // Both start at zero size with the card, so resizing it keeps them equal
    // to it; content left at its own size kept its extra height and sat the
    // line high.
    tint.frame = .zero
    blur.addSubview(tint)
    blur.addSubview(content)
    return blur
}

// Liquid Glass on macOS 26, tinted to the reference ack bubble's dark
// surface, #111212; the speaking capsule's, which the toast used until it took Siri's
// card. On macOS 14 and 15, the HUD blur with the same overlay.
@MainActor
func capsuleBackground(around content: NSView, radius: CGFloat = 30) -> NSView {
    let surface = NSColor(srgbRed: 0x11 / 255, green: 0x12 / 255, blue: 0x12 / 255, alpha: 0.85)
    content.autoresizingMask = [.width, .height]
    if #available(macOS 26, *) {
        let glass = NSGlassEffectView()
        glass.style = .regular
        glass.cornerRadius = radius
        glass.tintColor = surface
        glass.contentView = content
        return glass
    }
    let blur = NSVisualEffectView()
    blur.material = .hudWindow
    blur.blendingMode = .behindWindow
    blur.state = .active
    blur.wantsLayer = true
    blur.layer?.cornerRadius = radius
    blur.layer?.cornerCurve = .continuous
    blur.layer?.masksToBounds = true
    blur.layer?.borderWidth = 0.5
    blur.layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
    let tint = NSView()
    tint.wantsLayer = true
    tint.layer?.backgroundColor = surface.cgColor
    tint.autoresizingMask = [.width, .height]
    blur.addSubview(tint)
    blur.addSubview(content)
    return blur
}

// The capsule's content: transparent, laid out by hand so it follows the
// capsule's height through a resize, and it takes every click, including the
// first click into an inactive app, and a swipe up. The glass or blur behind
// it comes from capsuleBackground(around:).
private final class CapsuleView: NSView {
    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?

    // The banner's, by 15/13: 16 at the right, 14 above and below the lines.
    // The logo is drawn 24 wide, not in the 38 box (which only sets the
    // one-line height), 16 in and 12 from the text: larger read a touch big,
    // with too much space between.
    // Then 12 above and below, from 14, which was too much padding; the
    // sides went to 14 with it and back to 16.
    // The padding grows a little with the lines, so a four-line card isn't
    // cramped by the one-line pill's: 12 and 16 for one line, 14 and 18 for two, 16 and 20
    // for three or four. In steps, not by height, so bullet spacing doesn't
    // give odd values.
    // Then the reference bubble's 15 and 19 at every height.
    // Then the padding tightens as the lines are added, as three- and
    // two-line toasts had a little too much: one line keeps 15 and 19;
    // two lines are already clearly tighter, 13 and 18; then a gentle step,
    // 12 and 17 for three, 11 and 17 for four. The sides take the mark's
    // inset in with them. The line's height, the mark and the corner stay.
    private static let insets = [(15, 19), (13, 18), (12, 17), (11, 17)].map { vertical, side in
        NSEdgeInsets(top: CGFloat(vertical), left: CGFloat(side), bottom: CGFloat(vertical), right: CGFloat(side))
    }
    private var inset = CapsuleView.insets[0]
    // The bubble's 18 mark, 9 from the text.
    private static let spacing: CGFloat = 9
    static let markSize: CGFloat = 18

    static let maxLines = 4

    // The banner's text, regular, #E2E2E2, at 14.4pt (its 13 by 15/13 was 15;
    // tried at 14.8, 14.6 and 14.2 before settling on 14.4).
    // Then the bubble's: #E8E9EA, lines 1.45 apart, at 14.6, as its 15 felt
    // a little large.
    static let fontSize: CGFloat = 14.6
    static let font = NSFont.systemFont(ofSize: fontSize)
    static let textColor = NSColor(srgbRed: 0xE8 / 255, green: 0xE9 / 255, blue: 0xEA / 255, alpha: 1)
    static let lineHeight = (fontSize * 1.45).rounded()
    // The Claude mark in Anthropic's Ivory, for a dark surface.
    static let markColor = NSColor(srgbRed: 0xFA / 255, green: 0xF9 / 255, blue: 0xF5 / 255, alpha: 1)

    private let glyph = NSImageView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private let glyphSize: CGFloat
    private let maxWidth: CGFloat
    // The line's width, set by fittingSize(); the label keeps it through a
    // resize so the text doesn't rewrap while the card eases.
    private var textWidth: CGFloat
    private var text = ""

    init(maxWidth: CGFloat, glyphSize: CGFloat) {
        self.glyphSize = glyphSize
        self.maxWidth = maxWidth
        textWidth = maxWidth - Self.insets[0].left - Self.markSize - Self.spacing - Self.insets[0].right
        super.init(frame: NSRect(x: 0, y: 0, width: maxWidth, height: glyphSize))
        wantsLayer = true
        glyph.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: Self.markSize * 0.8, weight: .semibold)
        glyph.contentTintColor = Self.markColor
        glyph.wantsLayer = true
        label.font = Self.font
        label.textColor = Self.textColor
        // Four lines, the last cut with an ellipsis. Word wrapping with
        // truncatesLastVisibleLine: a truncating break mode would hold it to one.
        label.maximumNumberOfLines = Self.maxLines
        label.lineBreakMode = .byWordWrapping
        label.cell?.truncatesLastVisibleLine = true
        // A few pieces of Markdown (ToastText); nothing is a link or selectable.
        label.isSelectable = false
        label.wantsLayer = true
        // The swap blurs the glyph and the line, as Siri's answer swap does.
        for view in [glyph, label] as [NSView] {
            view.layerUsesCoreImageFilters = true
            let blur = CIFilter(name: "CIGaussianBlur")!
            blur.name = "blur"
            blur.setValue(0, forKey: kCIInputRadiusKey)
            view.layer?.filters = [blur]
        }
        addSubview(glyph)
        addSubview(label)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { nil }

    func set(glyph image: NSImage?, text: String, agent: String) {
        glyph.image = image
        self.text = text
        label.attributedStringValue = ToastText.attributed(text, font: Self.font, color: Self.textColor, lineHeight: Self.lineHeight)
        label.toolTip = agent
        needsLayout = true
    }

    private func textSize(width: CGFloat) -> NSSize {
        let size = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)) ?? .zero
        return NSSize(width: ceil(size.width), height: ceil(size.height))
    }

    // The text's one-line width up to the cap, and its height wrapped to it.
    // Text that wraps takes the full cap, so its lines are not ragged-narrow.
    // The padding is picked from the lines the text takes at the one-line
    // padding, then the text is fitted again inside it. The tighter sides
    // widen the line a little; text that then takes fewer lines than it was
    // counted at keeps the one-line width, so its padding still fits it.
    func fittingSize() -> NSSize {
        inset = Self.insets[0]
        fit()
        let lines = lineCount()
        let tier = Self.insets[min(max(lines, 1), Self.insets.count) - 1]
        if tier.left != inset.left || tier.top != inset.top {
            let oneLineWidth = textWidth
            inset = tier
            fit()
            if lineCount() < lines { fit(width: oneLineWidth) }
        }
        needsLayout = true
        let text = textSize(width: textWidth)
        return NSSize(width: inset.left + Self.markSize + Self.spacing + textWidth + inset.right,
                      height: max(glyphSize, text.height) + inset.top + inset.bottom)
    }

    // The lines the text takes at its current width.
    private func lineCount() -> Int {
        let lineHeight = ToastText.height(ToastText.attributed("x", font: Self.font, color: Self.textColor, lineHeight: Self.lineHeight),
                                          width: .greatestFiniteMagnitude)
        return Int((textSize(width: textWidth).height / max(1, lineHeight)).rounded())
    }

    // `width` caps the line below the padding's own cap.
    private func fit(width: CGFloat = .greatestFiniteMagnitude) {
        let cap = min(width, maxWidth - inset.left - Self.markSize - Self.spacing - inset.right)
        label.attributedStringValue = ToastText.attributed(text, font: Self.font, color: Self.textColor, lineHeight: Self.lineHeight)
        textWidth = min(cap, textSize(width: .greatestFiniteMagnitude).width)
        label.attributedStringValue = ToastText.fitted(text, font: Self.font, color: Self.textColor,
                                                       width: textWidth, maxLines: Self.maxLines,
                                                       lineHeight: Self.lineHeight)
    }

    override func layout() {
        super.layout()
        let midY = bounds.midY
        glyph.frame = NSRect(x: inset.left, y: (midY - Self.markSize / 2).rounded(),
                             width: Self.markSize, height: Self.markSize)
        let height = textSize(width: textWidth).height
        label.frame = NSRect(x: inset.left + Self.markSize + Self.spacing, y: (midY - height / 2).rounded(),
                             width: textWidth, height: height)
    }

    // The glyph and the line together, as the reference bubble's body moves.
    private var content: [CALayer] { [glyph.layer, label.layer].compactMap { $0 } }

    private static let blurKey = "filters.blur.inputRadius"

    // Clear, in place and at rest: a swap cut short by a close leaves the
    // line faded out.
    func resetContent() {
        for layer in content {
            layer.removeAnimation(forKey: "toast.swap")
            layer.opacity = 1
            layer.transform = CATransform3DIdentity
            layer.setValue(0, forKeyPath: Self.blurKey)
        }
    }

    func animateContent(opacity: Float, offset: CGFloat, blur: CGFloat, duration: TimeInterval,
                        timing: CAMediaTimingFunction) {
        for layer in content {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = layer.presentation()?.opacity ?? layer.opacity
            fade.toValue = opacity
            let move = CABasicAnimation(keyPath: "transform")
            move.fromValue = NSValue(caTransform3D: layer.presentation()?.transform ?? layer.transform)
            move.toValue = NSValue(caTransform3D: CATransform3DMakeTranslation(0, offset, 0))
            let soften = CABasicAnimation(keyPath: Self.blurKey)
            soften.fromValue = layer.presentation()?.value(forKeyPath: Self.blurKey) ?? 0
            soften.toValue = blur
            layer.setValue(blur, forKeyPath: Self.blurKey)
            let group = CAAnimationGroup()
            group.animations = [fade, move, soften]
            group.duration = duration
            group.timingFunction = timing
            layer.opacity = opacity
            layer.transform = CATransform3DMakeTranslation(0, offset, 0)
            group.preferredFrameRateRange = SpatialMotion.frameRate
            layer.add(group, forKey: "toast.swap")
        }
    }

    // In from a little below and out of a blur, on the in curve.
    func riseIn(from offset: CGFloat, blur: CGFloat) {
        let times = SpatialMotion.inCurve.map { NSNumber(value: $0.0) }
        for layer in content {
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = SpatialMotion.inCurve.map { NSNumber(value: $0.1) }
            fade.keyTimes = times
            let move = CAKeyframeAnimation(keyPath: "transform")
            move.values = SpatialMotion.inCurve.map {
                NSValue(caTransform3D: CATransform3DMakeTranslation(0, offset * (1 - $0.1), 0))
            }
            move.keyTimes = times
            let soften = CAKeyframeAnimation(keyPath: Self.blurKey)
            soften.values = SpatialMotion.inCurve.map { NSNumber(value: Double(blur) * (1 - $0.1)) }
            soften.keyTimes = times
            layer.setValue(0, forKeyPath: Self.blurKey)
            let group = CAAnimationGroup()
            group.animations = [fade, move, soften]
            group.duration = SpatialMotion.inDuration
            layer.opacity = 1
            layer.transform = CATransform3DIdentity
            group.preferredFrameRateRange = SpatialMotion.frameRate
            layer.add(group, forKey: "toast.swap")
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Labels inside swallow nothing: every click lands here.
        frame.contains(point) ? self : nil
    }

    // A click does nothing: only the × dismisses, so a stray click on the
    // toast never loses it.
    override func mouseDown(with event: NSEvent) {}

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    // A two-finger swipe up flicks the toast away.
    // Once per gesture, so one swipe never takes the next toast with it.
    private var swiped = false

    override func scrollWheel(with event: NSEvent) {
        if event.phase == .began { swiped = false }
        guard !swiped, event.phase == .began || event.phase == .changed else { return }
        // Fingers moving up, whichever way the user's scrolling runs.
        let delta = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
        if delta > 12 {
            swiped = true
            onClick?()
        }
    }
}
