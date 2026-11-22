import AppKit
import SiriusAdapters
import SiriusCore
import SiriusProtocol

// An agent's logo, always from a file: the one its registry folder holds
// (icon.svg, .png or .pdf beside agent.json, so people register the logo
// they want for their agent), else its harness's default
// mark, else a plain sparkle. No logo is drawn in code: the defaults are
// files, packaging/marks/<harness>.svg, which build-app.sh bundles at
// Contents/Resources/marks and onboarding copies into the agent's folder as
// icon.svg when it registers one (AgentRegistry.seedIcon).
//
// Decoded once per file and kept while the file is unchanged, so the
// composer and the toast read no SVG on open. A
// replaced logo has a new modification date and is read again.
@MainActor
enum AgentMarks {
    private struct Entry {
        let url: URL
        let modified: Date?
        let image: NSImage
    }

    private static var cache: [String: Entry] = [:]

    // The bundled default marks; without the bundle (`swift run`),
    // packaging/marks beside the working directory, as SkyImages.
    static var directory: URL {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("marks", isDirectory: true),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        return URL(fileURLWithPath: "packaging/marks", isDirectory: true)
    }

    // `harness` is the agent's when the caller knows it (onboarding, before
    // the agent is registered); otherwise it is read from agent.json.
    static func mark(agent: String, harness: AgentRegistration.Harness? = nil) -> NSImage? {
        guard let url = file(agent: agent, harness: harness) else {
            cache[agent] = nil
            return sparkle(agent)
        }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let entry = cache[agent], entry.url == url, entry.modified == modified {
            return entry.image
        }
        guard let source = NSImage(contentsOf: url), source.isValid, let image = rasterized(source) else {
            cache[agent] = nil
            return sparkle(agent)
        }
        cache[agent] = Entry(url: url, modified: modified, image: image)
        return image
    }

    private static func file(agent: String, harness: AgentRegistration.Harness?) -> URL? {
        let registry = AgentRegistry(directory: AgentHost.registryDirectory())
        let own = registry.icon(agent: agent)
        if let own, !isSeededCopy(own) { return own }
        guard let harness = harness ?? (try? registry.load(agent: agent).get())?.registration.harness else {
            return own
        }
        let url = AgentRegistry.defaultIcon(harness: harness, marks: directory)
        return FileManager.default.fileExists(atPath: url.path) ? url : own
    }

    // Whether an agent's icon is a copy onboarding seeded from an earlier
    // default mark, untouched since. Such a copy gives way to the current
    // default, so a mark fixed in the app (Gemini's gradient, Meta's for
    // Muse, OpenCode's favicon-informed mark) reaches agents set up before
    // the fix. A logo the person put there is not one and is kept. An svg
    // copy carries the comment naming its simple-icons source; a png copy
    // (OpenCode's) carries the tEXt marker the shipped file embeds, so a
    // fixed default retires every seeded copy of any version of it.
    static func isSeededCopy(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), data.count < 64_000 else { return false }
        switch url.pathExtension {
        case "svg":
            guard let text = String(data: data, encoding: .utf8) else { return false }
            return text.contains("<!-- simple-icons ")
        case "png":
            return data.range(of: Data("Sirius seeded default mark".utf8)) != nil
        default:
            return false
        }
    }

    // The mark drawn once by AppKit into a bitmap at 128 pixels a side.
    // SwiftUI draws an SVG's gradients in their first color only, so
    // Gemini's sparkle came out lavender and Meta's mark flat blue; AppKit's
    // own drawing keeps them. Vector-only files (PDF) are drawn the same way.
    static func rasterized(_ source: NSImage) -> NSImage? {
        guard source.size.width > 0, source.size.height > 0 else { return nil }
        let side = 128
        let scale = CGFloat(side) / max(source.size.width, source.size.height)
        let pixels = NSSize(width: (source.size.width * scale).rounded(), height: (source.size.height * scale).rounded())
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixels.width),
                                         pixelsHigh: Int(pixels.height), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        source.draw(in: NSRect(origin: .zero, size: pixels))
        NSGraphicsContext.restoreGraphicsState()
        rep.size = source.size
        let image = NSImage(size: source.size)
        image.addRepresentation(rep)
        image.accessibilityDescription = source.accessibilityDescription
        return image
    }

    private static var makers: [AgentChoice.Maker: NSImage] = [:]

    // A model maker's logo for a menu row: marks/makers/<maker>.svg, 14
    // points high and a template, so the menu tints it as it does its text.
    // nil without the file, and the row is then the name alone.
    static func maker(_ maker: AgentChoice.Maker) -> NSImage? {
        if let image = makers[maker] { return image }
        let url = directory.appendingPathComponent("makers/\(maker.rawValue).svg")
        guard let source = NSImage(contentsOf: url), source.isValid, source.size.height > 0 else { return nil }
        let height: CGFloat = 14
        let size = NSSize(width: (source.size.width / source.size.height * height).rounded(), height: height)
        let image = NSImage(size: size, flipped: false) { rect in
            source.draw(in: rect)
            return true
        }
        image.isTemplate = true
        makers[maker] = image
        return image
    }

    private static func sparkle(_ agent: String) -> NSImage? {
        SiriusMark.template(agent)
    }
}
