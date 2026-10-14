import AppKit

// The composer's surface, for anything that should read as the same object:
// the HUD blur held active and dark, the panel's colour over it
// (Palette.glassFill) and its 1pt border (Palette.border) on top, at the
// given corner. A blur, not Liquid Glass, for the composer's reason
// (ComposerBackground): NSGlassEffectView changes its surface when the window
// loses focus. Kept for the dictation pill, which is to match the
// composer's surface; the toast keeps its own style.
// TODO(copy): ComposerBackground still sets the same up inline; it can call
// this once it is free to change.
@MainActor
func installComposerSurface(in view: NSView, radius: CGFloat) {
    view.wantsLayer = true
    let blur = NSVisualEffectView(frame: view.bounds)
    blur.appearance = NSAppearance(named: .darkAqua)
    blur.material = .hudWindow
    blur.blendingMode = .behindWindow
    blur.state = .active
    blur.autoresizingMask = [.width, .height]
    view.addSubview(blur)
    let fill = NSView(frame: view.bounds)
    fill.wantsLayer = true
    fill.layer?.backgroundColor = Palette.glassFill.cgColor
    fill.autoresizingMask = [.width, .height]
    view.addSubview(fill)
    // A layer's border draws above its sublayers, so over the blur and fill.
    view.layer?.borderColor = Palette.border.cgColor
    view.layer?.borderWidth = 1
    view.layer?.cornerRadius = radius
    view.layer?.cornerCurve = .continuous
    view.layer?.masksToBounds = true
}

// The composer's shadow, for a transparent window whose content is the
// surface above: the standard window shadow, which the window server draws
// from the content's alpha, so it follows the surface's rounded corners.
// The window is light, though the surface draws dark: the window server rims
// a dark-appearance window's shadow with a light line, which read too bright
// on this surface. The shadow itself stays, as Spatial's Scratch Pad has
// the standard one. Trial. A window whose surface changes
// shape must call invalidateShadow() as it does, or the shadow keeps the old
// one.
@MainActor
func applyComposerWindowShadow(to window: NSWindow) {
    window.backgroundColor = .clear
    window.isOpaque = false
    window.hasShadow = true
    window.appearance = NSAppearance(named: .aqua)
}
