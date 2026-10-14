import AppKit
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

// An attached file as a thumbnail, as a capture tile: 64 × 64,
// radius 10, a 1px #3a3d41 edge on #2d3034, the image filling the tile, and
// a round × at the top right on hover that removes it. Images and videos
// show their Quick Look thumbnail, anything else its Finder icon.
@MainActor
final class AttachmentTile: NSView {
    static let side: CGFloat = 64
    var onRemove: (() -> Void)?
    let url: URL

    private let image = NSImageView()
    private let remove = NSButton()

    init(url: URL) {
        self.url = url
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(srgbRed: 0x3A / 255, green: 0x3D / 255, blue: 0x41 / 255, alpha: 1).cgColor
        layer?.backgroundColor = NSColor(srgbRed: 0x2D / 255, green: 0x30 / 255, blue: 0x34 / 255, alpha: 1).cgColor
        toolTip = url.lastPathComponent
        setAccessibilityLabel(url.lastPathComponent)

        image.frame = bounds
        image.autoresizingMask = [.width, .height]
        image.imageScaling = .scaleAxesIndependently
        image.image = NSWorkspace.shared.icon(forFile: url.path)
        addSubview(image)

        // The ×: 18 round, 3 in from the corner, white on 65% black.
        remove.frame = NSRect(x: Self.side - 3 - 18, y: Self.side - 3 - 18, width: 18, height: 18)
        remove.isBordered = false
        remove.wantsLayer = true
        remove.layer?.cornerRadius = 9
        remove.layer?.backgroundColor = NSColor(white: 0, alpha: 0.65).cgColor
        remove.attributedTitle = NSAttributedString(string: "×", attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.white,
        ])
        remove.target = self
        remove.action = #selector(removeClicked)
        remove.isHidden = true
        remove.setAccessibilityLabel("Remove \(url.lastPathComponent)")
        addSubview(remove)

        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
        loadThumbnail()
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.side, height: Self.side) }

    override func mouseEntered(with event: NSEvent) { remove.isHidden = false }
    override func mouseExited(with event: NSEvent) { remove.isHidden = true }

    @objc private func removeClicked() { onRemove?() }

    // Filled to the tile, cropped as object-fit: cover, and drawn at the
    // tile's pixel size. The source is decoded so its short side covers the
    // tile at the sharpest screen attached; a fit-in-64 thumbnail cropped to
    // its short side was upscaled, which blurred wide screenshots.
    private var source: CGImage?

    private var backingScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let source { show(cover: source) }
    }

    private func loadThumbnail() {
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        let pixels = Self.side * scale
        let url = url
        // Images decode straight from the file through ImageIO; the rest go
        // through Quick Look, asked for a box wide enough to cover at 3:1.
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let cg = Self.decode(url, coverPixels: pixels) else { return }
                DispatchQueue.main.async { self?.show(cover: cg) }
            }
            return
        }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: Self.side * 3, height: Self.side * 3),
                                                   scale: scale, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] thumbnail, _ in
            guard let cg = thumbnail?.cgImage else { return }
            DispatchQueue.main.async { self?.show(cover: cg) }
        }
    }

    // A thumbnail whose short side is at least `coverPixels`, oriented.
    private nonisolated static func decode(_ url: URL, coverPixels: CGFloat) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let h = props[kCGImagePropertyPixelHeight] as? CGFloat, w > 0, h > 0 else { return nil }
        let maxPixels = min(max(w, h), (coverPixels * max(w, h) / min(w, h)).rounded(.up))
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ] as CFDictionary)
    }

    // The centre square, resampled with high interpolation into a bitmap of
    // exactly the tile's pixels, so the image view draws it 1:1.
    private func show(cover cg: CGImage) {
        source = cg
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let pixels = Int((Self.side * backingScale).rounded())
        guard w > 0, h > 0, pixels > 0 else { return }
        let space = cg.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        ctx.interpolationQuality = .high
        let fill = CGFloat(pixels) / min(w, h)
        ctx.draw(cg, in: CGRect(x: (CGFloat(pixels) - w * fill) / 2, y: (CGFloat(pixels) - h * fill) / 2,
                                width: w * fill, height: h * fill))
        guard let square = ctx.makeImage() else { return }
        image.image = NSImage(cgImage: square, size: NSSize(width: Self.side, height: Self.side))
    }
}
