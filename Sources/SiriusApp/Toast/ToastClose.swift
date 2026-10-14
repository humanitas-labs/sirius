import AppKit

// The × that appears on the toast's top-left corner while the pointer is on
// it, as on a macOS notification banner, not only the click on the toast. The banner draws it half outside the card, and the toast's window
// is only the card, so the × is its own small window, a child of the toast's,
// on the toast's glass. Shown and hidden with a short fade; clicking it
// dismisses, and the pointer on it holds the toast as on the toast itself.
// TODO(copy): the size and the overhang are a first pass from his capture.
@MainActor
final class ToastClose: NSPanel {
    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?

    // 20 on the banner, by 15/13.
    static let diameter: CGFloat = 23
    // The ×'s centre, in from the card's top-left corner on both axes.
    static let inset: CGFloat = 5
    private static let fade: TimeInterval = 0.15

    private let button = CloseView()
    private(set) var isShown = false

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        appearance = NSAppearance(named: .aqua)
        button.onClick = { [weak self] in self?.onClick?() }
        button.onHover = { [weak self] in self?.onHover?($0) }
        contentView = toastCard(around: button, radius: Self.diameter / 2)
        alphaValue = 0
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // Centred `inset` in from the top-left of `card`, in screen coordinates.
    func place(on card: NSRect) {
        let centre = NSPoint(x: card.minX + Self.inset, y: card.maxY - Self.inset)
        setFrame(NSRect(x: (centre.x - Self.diameter / 2).rounded(), y: (centre.y - Self.diameter / 2).rounded(),
                        width: Self.diameter, height: Self.diameter), display: false)
    }

    func show(above parent: NSWindow) {
        guard !isShown else { return }
        isShown = true
        if self.parent !== parent { parent.addChildWindow(self, ordered: .above) }
        orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fade
            animator().alphaValue = 1
        }
    }

    func hide(animated: Bool = true) {
        guard isShown else { return }
        isShown = false
        guard animated else {
            alphaValue = 0
            return detach()
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fade
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isShown else { return }
                self.detach()
            }
        })
    }

    private func detach() {
        parent?.removeChildWindow(self)
        orderOut(nil)
    }
}

// The × itself, the system's xmark, centred; takes the click and the hover.
@MainActor
private final class CloseView: NSView {
    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    private let mark = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        mark.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")
        // Nearly half the circle, as the banner's is; 9pt read a bit small.
        mark.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        mark.contentTintColor = NSColor(white: 1, alpha: 0.8)
        addSubview(mark)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
        setAccessibilityRole(.button)
        setAccessibilityLabel("Dismiss")
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let size = mark.intrinsicContentSize
        mark.frame = NSRect(x: ((bounds.width - size.width) / 2).rounded(),
                            y: ((bounds.height - size.height) / 2).rounded(), width: size.width, height: size.height)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}
