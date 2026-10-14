import AppKit
import QuartzCore

// Open and close, copied from Spatial's quick note panel (values read from
// its bundle): a critically damped spring on scale from
// the centre, no fade, no slide. Open: 0.05 s after the panel shows, 0 → 1,
// stiffness 100, mass 0.16, an ease-out sine curve over the spring's
// settling time. Close: → 0, stiffness 200, mass 0.12, ease-in sine; the
// panel goes once the spring has visibly settled (0.154 s at Spatial's pace).
// Slowed, as Spatial's read a little too fast: its measured 240/220 ms run
// a third slower, 310/290 ms, so time here runs 4/3 as long. The springs keep their shape: stiffness goes
// down by (3/4)², mass and damping ratio stay.
// Shared by the composer and the toast. The toast's swap (ToastPanel) eases
// on its own in curve, inCurve below.
@MainActor
enum SpatialMotion {
    static let hidden: CGFloat = 0.0001
    nonisolated static let slower: Double = 4.0 / 3
    // Debug slow motion (the menu's Option-click Debug items): every
    // duration here and in the toast's swap runs this many times as long.
    static var timeScale: Double = 1
    static var openDelay: TimeInterval { 0.05 * timeScale }
    static var closeGone: TimeInterval { 0.154 * slower * timeScale }
    static var inDuration: TimeInterval { 0.31 * timeScale }
    // Every animation and display link asks for the screen's top rate:
    // 120 Hz on a ProMotion display, where the default lets macOS choose
    // lower to save power. A 60 Hz screen stays at 60, its maximum.
    static let frameRate = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)

    // --spatial-in-ease, the CSS linear() curve, stop for stop: (time, progress).
    static let inCurve: [(Double, Double)] = [
        (0, 0), (0.03, 0.194), (0.06, 0.35), (0.10, 0.512), (0.14, 0.634), (0.19, 0.744), (0.25, 0.834),
        (0.32, 0.9), (0.40, 0.944), (0.50, 0.973), (0.62, 0.989), (0.75, 0.996), (1, 1),
    ]
    // --spatial-out-ease.
    static let outCurve = CAMediaTimingFunction(controlPoints: 0.5, 0, 0.3, 1)

    // The in curve's progress at t in 0...1, linear between the stops as
    // linear() is.
    static func inProgress(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        for i in 1..<inCurve.count where t <= inCurve[i].0 {
            let (t0, p0) = inCurve[i - 1], (t1, p1) = inCurve[i]
            return p0 + (p1 - p0) * (t - t0) / (t1 - t0)
        }
        return 1
    }

    // Springs the view open about the centre of `rect` (its bounds by default).
    // `pace` stretches time as `slower` does; the composer opens at
    // Spatial's own pace, 1, so typing can start at once; the close stays
    // slowed.
    static func open(_ view: NSView?, about rect: NSRect? = nil, pace: Double = slower) {
        guard let view, let layer = view.layer else { return }
        let rect = rect ?? view.bounds
        layer.removeAllAnimations()
        layer.transform = scale(hidden, in: rect)
        DispatchQueue.main.asyncAfter(deadline: .now() + openDelay) {
            animate(layer, in: rect, to: 1, stiffness: 100, mass: 0.16, pace: pace,
                    curve: CAMediaTimingFunction(controlPoints: 0.39, 0.575, 0.565, 1.0))
        }
    }

    // Springs the view shut about the centre of `rect`, then calls done. The
    // returned timer can be invalidated to call the close off.
    static func close(_ view: NSView?, about rect: NSRect? = nil,
                      done: @escaping @MainActor () -> Void) -> Timer {
        if let view, let layer = view.layer {
            animate(layer, in: rect ?? view.bounds, to: hidden, stiffness: 200, mass: 0.12, pace: slower,
                    curve: CAMediaTimingFunction(controlPoints: 0.47, 0, 0.745, 0.715))
        }
        return Timer.scheduledTimer(withTimeInterval: closeGone, repeats: false) { _ in
            MainActor.assumeIsolated {
                view?.layer?.removeAllAnimations()
                view?.layer?.transform = CATransform3DIdentity
                done()
            }
        }
    }

    private static func animate(_ layer: CALayer, in rect: NSRect, to target: CGFloat,
                                stiffness: CGFloat, mass: CGFloat, pace: Double, curve: CAMediaTimingFunction) {
        // Time stretched by `pace`: ω = √(k/m) falls by the same factor.
        let k = stiffness / CGFloat(pace * pace)
        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = layer.presentation()?.transform ?? layer.transform
        spring.toValue = scale(target, in: rect)
        spring.stiffness = k
        spring.mass = mass
        // Critical damping, as Spatial's maximal damping without overdamping
        // works out to: 2√(km).
        spring.damping = 2 * (k * mass).squareRoot()
        spring.initialVelocity = 0
        spring.timingFunction = curve
        spring.preferredFrameRateRange = frameRate
        spring.duration = spring.settlingDuration
        spring.speed = Float(1 / timeScale)
        layer.transform = scale(target, in: rect)
        layer.add(spring, forKey: "spatial")
    }

    // A scale about the centre of rect; AppKit pins a view's layer anchor at
    // its origin, so the transform carries the centring itself.
    static func scale(_ s: CGFloat, in rect: NSRect) -> CATransform3D {
        let cx = rect.midX, cy = rect.midY
        var t = CATransform3DMakeTranslation(cx, cy, 0)
        t = CATransform3DScale(t, s, s, 1)
        return CATransform3DTranslate(t, -cx, -cy, 0)
    }
}
