import AppKit

// Sirius's mark: the silver star (packaging/images/sirius-star.png, made by
// scripts/make-icon.sh). `silver` is the star in its own colors, for dark
// surfaces; `template` is the same shape for macOS to tint, as the pill tints
// it blue. Both fall back to the SF Symbol "sparkle" when the bundle lacks the
// file, as in `swift run` from a checkout without packaging/.
enum SiriusMark {
    static let silver: NSImage? = {
        let url = Bundle.main.url(forResource: "sirius-star", withExtension: "png", subdirectory: "images")
            ?? URL(fileURLWithPath: "packaging/images/sirius-star.png")
        guard let image = NSImage(contentsOf: url), image.isValid else { return nil }
        image.accessibilityDescription = "Sirius"
        return image
    }()

    // The star for tinting at small sizes: the same shape with its alpha
    // raised (scripts/make-icon.sh), so the thin tips of its arms stay
    // visible instead of fading out and reading as cut off.
    static let mark: NSImage? = {
        let url = Bundle.main.url(forResource: "sirius-star-mark", withExtension: "png", subdirectory: "images")
            ?? URL(fileURLWithPath: "packaging/images/sirius-star-mark.png")
        guard let image = NSImage(contentsOf: url), image.isValid else { return nil }
        image.isTemplate = true
        return image
    }()

    // How much larger than the pill's 20 pt content the star is drawn, so it
    // fills the 46 pt capsule as the symbol it replaced did.
    static let pillScale: CGFloat = 1

    static func template(_ description: String? = "Sirius") -> NSImage? {
        guard let star = (mark ?? silver)?.copy() as? NSImage else {
            return NSImage(systemSymbolName: "sparkle", accessibilityDescription: description)
        }
        star.isTemplate = true
        star.accessibilityDescription = description
        return star
    }

    // The tinted star with its soft glow, rendered once on the CPU into a
    // bitmap and cached per color. The pill used to tint and glow it live
    // through .drawingGroup() and .shadow, which built a Metal offscreen
    // pass on the first press after launch or idle and held up the pill.
    @MainActor private static var glowing: [String: NSImage] = [:]

    @MainActor static func glowing(_ color: NSColor, side: CGFloat, glow: CGFloat) -> NSImage? {
        guard let star = mark ?? silver else { return nil }
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let key = "\(rgb.redComponent),\(rgb.greenComponent),\(rgb.blueComponent),\(rgb.alphaComponent),\(side),\(glow)"
        if let cached = glowing[key] { return cached }
        let scale: CGFloat = 2
        let pad = (glow * 3).rounded(.up)
        let full = side + pad * 2
        let px = Int(full * scale)
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cgStar = star.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        let rect = CGRect(x: pad, y: pad, width: side, height: side)
        // The tinted star alone, then drawn again with its glow.
        let tinted = CGContext(data: nil, width: Int(side * scale), height: Int(side * scale), bitsPerComponent: 8,
                               bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let local = CGRect(x: 0, y: 0, width: side * scale, height: side * scale)
        tinted.clip(to: local, mask: cgStar)
        tinted.setFillColor(rgb.cgColor)
        tinted.fill(local)
        guard let shape = tinted.makeImage() else { return nil }
        ctx.setShadow(offset: .zero, blur: glow * 2, color: rgb.withAlphaComponent(0.75 * rgb.alphaComponent).cgColor)
        ctx.draw(shape, in: rect)
        guard let out = ctx.makeImage() else { return nil }
        let image = NSImage(cgImage: out, size: NSSize(width: full, height: full))
        image.accessibilityDescription = "Sirius"
        glowing[key] = image
        return image
    }

    // The padding glowing(_:side:glow:) adds on each side, for frames.
    static func glowPadding(_ glow: CGFloat) -> CGFloat { (glow * 3).rounded(.up) }
}
