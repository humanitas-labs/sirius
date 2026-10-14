import AppKit

// A debug path for reviewing the composer's growth, scrolling and fades
// without opening it on screen: `Sirius --composer-snapshots <dir>` renders
// the panel off every screen at 2x to <dir>/<name>.png and exits before the
// socket server starts, as OnboardingSnapshots does.
@MainActor
enum ComposerSnapshots {
    static let flag = "--composer-snapshots"

    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return }
        let directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let long = (1...30).map { "Line \($0): the composer grows to twelve lines, then scrolls with fades." }
            .joined(separator: "\n")
        let shots: [(name: String, text: String, scroll: CGFloat?)] = [
            ("1-short", "Summarise the open pull requests and flag anything blocked.", nil),
            ("2-long-bottom", long, 1),
            ("3-long-middle", long, 0.5),
            ("4-long-top", long, 0),
        ]
        for shot in shots {
            let panel = ComposerPanel()
            panel.setAgent(name: "Claude", mark: AgentMarks.mark(agent: "claude"))
            panel.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            panel.textView.string = shot.text
            panel.fitHeight()
            let clip = panel.textView.enclosingScrollView?.contentView
            if let fraction = shot.scroll, let clip {
                let range = panel.textView.frame.height - clip.bounds.height
                clip.scroll(to: NSPoint(x: 0, y: (range * fraction).rounded()))
                panel.textView.enclosingScrollView?.reflectScrolledClipView(clip)
            }
            panel.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            guard let content = panel.contentView, let image = render(content) else {
                FileManager.default.createFile(atPath: directory.path + "/FAILED-\(shot.name)", contents: nil)
                continue
            }
            panel.orderOut(nil)
            let url = directory.appendingPathComponent("\(shot.name).png")
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
            print("\(url.path) \(Int(panel.frame.height))pt")
        }
        exit(0)
    }

    // The view at 2x, through its layer tree so the fade mask shows:
    // cacheDisplay draws the views and skips layer masks.
    private static func render(_ view: NSView) -> CGImage? {
        guard let layer = view.layer else { return nil }
        let scale: CGFloat = 2
        let size = view.bounds.size
        guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        return context.makeImage()
    }
}
