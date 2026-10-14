import AppKit

// The colour on arrival, in the border only: a ring flash, ported from an
// earlier web implementation as it was tuned there.
//
// A band of light rolls out from a point near the middle as a slightly
// oblong ellipse, different each time, and shows only where it crosses the
// 1.5pt border: fast at first, settling, never stopping, over 3 s, starting
// 95 ms in, when the spring-in has all but landed. The colour holds at 84%
// for the first 30% and then fades. The gradient is new for each arrival,
// from Sirius's night sky: mostly blue to indigo, some aurora green, now and
// then a sunset plum.
//
// Layers: `layer` is masked by the wave (a radial gradient whose stops move)
// and holds the conic gradient, which is masked to the border.
@MainActor
final class SplashRing {
    let view = RingView()

    private let container = CALayer()
    private let colours = CAGradientLayer()
    private let border = CALayer()
    private let wave = CAGradientLayer()
    private let radius: CGFloat

    static let width: CGFloat = 1.5
    static let duration: CFTimeInterval = 3
    static let delay: CFTimeInterval = 0.095
    static let peak: Float = 0.84
    // The wave's soft leading edge and the band's trailing one (--ack-edge).
    static let edge: CGFloat = 30
    // The ellipse's radius reaches the farthest corner at 100%; the wave runs
    // to 250%, so the gradient spans that.
    private static let reach: CGFloat = 250

    // The original's keyframes: (time, opacity, wave %, tail %).
    static let keyframes: [(t: Double, opacity: Float, wave: CGFloat, tail: CGFloat)] = [
        (0, 0.84, 0, -15), (0.032, 0.84, 25, 0), (0.064, 0.84, 48.1, 13.9), (0.104, 0.84, 74.4, 29.6),
        (0.16, 0.84, 106.8, 49.1), (0.24, 0.84, 144.9, 71.9), (0.30, 0.84, 167.9, 85.8),
        (0.40, 0.677, 197.4, 103.4), (0.50, 0.524, 217.6, 115.6), (0.60, 0.384, 230.9, 123.5),
        (0.70, 0.257, 239.2, 128.5), (0.80, 0.145, 244.2, 131.5), (0.90, 0.055, 247.4, 133.5),
        (1, 0, 250, 135),
    ]

    // `cornerCurve`: the toast's card is continuous; the dictation pill, a
    // capsule at half its height, is circular, as a continuous curve at
    // that radius draws its sides past the corners.
    init(radius: CGFloat, cornerCurve: CALayerCornerCurve = .continuous) {
        self.radius = radius
        view.wantsLayer = true
        view.layer?.addSublayer(container)
        container.opacity = 0
        container.addSublayer(colours)
        container.mask = wave
        colours.type = .conic
        colours.startPoint = CGPoint(x: 0.5, y: 0.5)
        colours.endPoint = CGPoint(x: 0.5, y: 1)
        colours.mask = border
        border.borderWidth = Self.width
        border.borderColor = NSColor.black.cgColor
        border.cornerRadius = radius
        border.cornerCurve = cornerCurve
        wave.type = .radial
        wave.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        wave.locations = [0, 0, 0, 0]
    }

    // The card's frame, in the superview's coordinates.
    func setFrame(_ frame: NSRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.frame = frame
        for layer in [container, colours, border, wave] { layer.frame = CGRect(origin: .zero, size: frame.size) }
        CATransaction.commit()
    }

    // The ring at `size`, centred in its view, in place of the view's whole
    // frame: for a card that grows while the ring plays (the launch cue's
    // pill, which widens to say "Listening."), the view framed at the
    // largest size. Moves over `duration` on `timing`, or at once for 0.
    func resize(to size: CGSize, duration: CFTimeInterval = 0, timing: CAMediaTimingFunction? = nil) {
        let bounds = view.bounds
        CATransaction.begin()
        if duration > 0 {
            CATransaction.setAnimationDuration(duration)
            CATransaction.setAnimationTimingFunction(timing)
        } else {
            CATransaction.setDisableActions(true)
        }
        container.frame = CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                                 width: size.width, height: size.height)
        for layer in [colours, border, wave] { layer.frame = CGRect(origin: .zero, size: size) }
        CATransaction.commit()
    }

    // One splash, with a new gradient and shape. None under Reduce Motion.
    func splash() {
        container.removeAllAnimations()
        wave.removeAllAnimations()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let size = container.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        var random = SystemRandomNumberGenerator()
        prepare(size: size, using: &random)

        let begin = CACurrentMediaTime() + Self.delay
        let times = Self.keyframes.map { NSNumber(value: $0.t) }
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = Self.keyframes.map(\.opacity)
        fade.keyTimes = times
        let band = CAKeyframeAnimation(keyPath: "locations")
        band.values = Self.keyframes.map { Self.stops(wave: $0.wave, tail: $0.tail) }
        band.keyTimes = times
        for (animation, layer) in [(fade, container), (band, wave)] as [(CAKeyframeAnimation, CALayer)] {
            animation.calculationMode = .linear
            animation.duration = Self.duration
            animation.beginTime = begin
            animation.fillMode = .backwards
            layer.add(animation, forKey: "splash")
        }
    }

    func stop() {
        container.removeAllAnimations()
        wave.removeAllAnimations()
    }

    // A new gradient and shape, for a splash or a pose.
    private func prepare<R: RandomNumberGenerator>(size: CGSize, using random: inout R) {
        let gradient = Self.gradient(using: &random)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        colours.colors = gradient.colors
        colours.locations = gradient.locations
        let shape = Self.shape(width: size.width, height: size.height, using: &random)
        wave.startPoint = shape.centre
        wave.endPoint = CGPoint(x: shape.centre.x + shape.rx * Self.reach / 100 / size.width,
                                y: shape.centre.y + shape.ry * Self.reach / 100 / size.height)
        CATransaction.commit()
    }

    // The splash held still `seconds` after it starts (past the delay), as
    // the layers' own values with no animation, so a layer render shows it:
    // for the launch snapshots (LaunchSnapshots). The keyframes are
    // interpolated linearly, as the animation does; `random` picks the
    // gradient and the shape.
    func pose<R: RandomNumberGenerator>(at seconds: Double, using random: inout R) {
        stop()
        let size = container.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        prepare(size: size, using: &random)
        let t = min(max(seconds / Self.duration, 0), 1)
        let frames = Self.keyframes
        let after = frames.firstIndex { $0.t >= t } ?? frames.count - 1
        let before = max(after - 1, 0)
        let (a, b) = (frames[before], frames[after])
        let f = b.t > a.t ? (t - a.t) / (b.t - a.t) : 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.opacity = a.opacity + (b.opacity - a.opacity) * Float(f)
        wave.locations = Self.stops(wave: a.wave + (b.wave - a.wave) * CGFloat(f),
                                    tail: a.tail + (b.tail - a.tail) * CGFloat(f))
        CATransaction.commit()
    }

    // The band's four stops as fractions of the gradient's reach: clear at
    // tail − edge, solid from tail to wave − edge, clear at the wave. A stop
    // behind the one before it moves up to it, as CSS does.
    static func stops(wave: CGFloat, tail: CGFloat) -> [NSNumber] {
        var last: CGFloat = 0
        return [tail - edge, tail, wave - edge, wave].map { percent in
            last = max(last, percent / reach)
            return NSNumber(value: Double(min(1, last)))
        }
    }

    // The shape: a centre near the middle and an ellipse stretched
    // up to 28% either way, its radius reaching the farthest corner at 100%.
    // Unit coordinates for the centre, points for the radii.
    static func shape<R: RandomNumberGenerator>(width w: CGFloat, height h: CGFloat, using random: inout R)
        -> (centre: CGPoint, rx: CGFloat, ry: CGFloat) {
        let sx = 0.78 + CGFloat.random(in: 0..<1, using: &random) * 0.5
        let sy = 0.78 + CGFloat.random(in: 0..<1, using: &random) * 0.5
        let cx = 0.38 + CGFloat.random(in: 0..<1, using: &random) * 0.24
        let cy = 0.3 + CGFloat.random(in: 0..<1, using: &random) * 0.4
        let corners = [(0, 0), (w, 0), (0, h), (w, h)]
        let r = corners.map { hypot(($0.0 - cx * w) / sx, ($0.1 - cy * h) / sy) }.max() ?? 0
        return (CGPoint(x: cx, y: cy), r * sx, r * sy)
    }

    // The colour families: night, aurora, sunset.
    static let families: [(weight: Double, from: Double, to: Double)] = [
        (0.55, 205, 265), (0.3, 155, 250), (0.15, 255, 330),
    ]

    // The gradient: 3 or 4 hues across most of a family's range from
    // a random start, saturation 72–84% and lightness 67–73%, out to the far
    // hue at half-way and back, so the seam at the top matches.
    static func gradient<R: RandomNumberGenerator>(using random: inout R) -> (colors: [CGColor], locations: [NSNumber]) {
        func unit() -> Double { Double.random(in: 0..<1, using: &random) }
        func colour(_ hue: Double) -> CGColor {
            hsl(hue: hue, saturation: (72 + unit() * 12).rounded() / 100, lightness: (67 + unit() * 6).rounded() / 100)
        }
        var pick = unit()
        let family = families.first { pick -= $0.weight; return pick < 0 } ?? families[0]
        let n = unit() < 0.5 ? 3 : 4
        let range = family.to - family.from
        let span = range * (0.7 + unit() * 0.3)
        let base = family.from + unit() * (range - span)
        let forward = unit() < 0.5
        let hues = (0..<n).map { i in
            colour(forward ? base + span * Double(i) / Double(n - 1) : base + span - span * Double(i) / Double(n - 1))
        }
        let at = (0..<n).map { 0.5 * Double($0) / Double(n - 1) }
        let colors = hues + hues.dropLast().reversed()
        let locations = at + at.dropLast().reversed().map { 1 - $0 }
        return (colors, locations.map { NSNumber(value: $0) })
    }

    // CSS hsl() to sRGB.
    static func hsl(hue: Double, saturation s: Double, lightness l: Double) -> CGColor {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360
        func channel(_ n: Double) -> Double {
            let k = (n + h * 12).truncatingRemainder(dividingBy: 12)
            return l - s * min(l, 1 - l) * max(-1, min(k - 3, 9 - k, 1))
        }
        return CGColor(srgbRed: channel(0), green: channel(8), blue: channel(4), alpha: 1)
    }
}

// Draws the ring and takes no clicks or hover; they go to the card below.
final class RingView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
