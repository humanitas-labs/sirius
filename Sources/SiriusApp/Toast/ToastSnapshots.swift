import AppKit

// A debug path for checking the toast's colour: `Sirius --toast-snapshots
// <dir>` presents the toast off every screen over the dark page it was
// reported on (#0B0B0B), writes each shot to <dir>/<name>.png,
// prints the colour of the card's body, and exits before the socket server
// starts, as ComposerSnapshots does. The shot is the window as the window
// server composites it, so the Liquid Glass shows, which a layer render
// skips; only Sirius's own window is captured, which needs no
// screen-recording grant.
// With `--bright-first` it first replays the bright-toast report on screen, at the main
// screen's bottom-left corner for about 10 s: a short toast over a white
// window, then a long one with the window turned dark. The glass adapted to
// the white and, once larger, kept the light look (#404041); held dark it
// stays #18181A.
@MainActor
enum ToastSnapshots {
    static let flag = "--toast-snapshots"
    static let brightFirst = "--bright-first"
    private static let ground = NSColor(srgbRed: 0x0B / 255, green: 0x0B / 255, blue: 0x0B / 255, alpha: 1)
    private static let short = "Done."
    private static let long = "Filed ENG-142: toasts sometimes much brighter than expected, conditions unknown. "
        + "A screenshot next time it happens would pin it down."

    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return }
        let directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if arguments.contains(brightFirst) {
            replayBrightFirst(to: directory)
        }
        for shot in [(name: "1-short", text: short), (name: "2-long", text: long)] {
            let panel = ToastPanel()
            panel.present(agent: "claude", mark: AgentMarks.mark(agent: "claude"), text: shot.text)
            panel.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            // Past the spring-in and the ring's splash.
            RunLoop.main.run(until: Date().addingTimeInterval(SplashRing.delay + SplashRing.duration + 0.3))
            write(panel, name: shot.name, to: directory)
            panel.orderOut(nil)
        }
        exit(0)
    }

    private static func replayBrightFirst(to directory: URL) {
        guard let screen = NSScreen.main?.frame else { return }
        let page = NSPanel(contentRect: NSRect(x: screen.minX, y: screen.minY, width: 700, height: 200),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        page.backgroundColor = .white
        page.level = .floating
        page.orderFrontRegardless()
        let corner = NSPoint(x: screen.minX + 20, y: screen.minY + 20)
        let panel = ToastPanel()
        panel.present(agent: "claude", mark: AgentMarks.mark(agent: "claude"), text: short)
        panel.setFrameOrigin(corner)
        RunLoop.main.run(until: Date().addingTimeInterval(4))
        panel.present(agent: "claude", mark: AgentMarks.mark(agent: "claude"), text: long)
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        panel.setFrameOrigin(corner)
        page.backgroundColor = ground
        RunLoop.main.run(until: Date().addingTimeInterval(4))
        write(panel, name: "0-bright-first", to: directory)
        panel.orderOut(nil)
        page.orderOut(nil)
    }

    private static func write(_ panel: NSPanel, name: String, to directory: URL) {
        guard let image = capture(panel) else {
            FileManager.default.createFile(atPath: directory.path + "/FAILED-\(name)", contents: nil)
            return
        }
        let url = directory.appendingPathComponent("\(name).png")
        let bitmap = NSBitmapImageRep(cgImage: image)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        // 20pt in from the card's right edge, at its middle, clear of the text.
        let colour = bitmap.colorAt(x: bitmap.pixelsWide - 40, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB)
        let hex = colour.map {
            String(format: "#%02X%02X%02X", Int($0.redComponent * 255 + 0.5), Int($0.greenComponent * 255 + 0.5),
                   Int($0.blueComponent * 255 + 0.5))
        } ?? "?"
        print("\(url.path) body \(hex)")
    }

    // The panel made opaque in the ground's colour for the shot, so the glass
    // lies over it, and only its own window captured.
    private static func capture(_ panel: NSPanel) -> CGImage? {
        panel.backgroundColor = ground
        panel.isOpaque = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        typealias Create = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        // CGWindowListCreateImage, which the macOS 15 SDK marks unavailable.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(symbol, to: Create.self)
        let includingWindow: UInt32 = 1 << 3
        let boundsIgnoreFraming: UInt32 = 1 << 0, bestResolution: UInt32 = 1 << 3
        return create(.null, includingWindow, UInt32(panel.windowNumber), boundsIgnoreFraming | bestResolution)?
            .takeRetainedValue()
    }
}
