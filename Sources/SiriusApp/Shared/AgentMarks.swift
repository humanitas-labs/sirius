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
        guard let image = NSImage(contentsOf: url), image.isValid else {
            cache[agent] = nil
            return sparkle(agent)
        }
        cache[agent] = Entry(url: url, modified: modified, image: image)
        return image
    }

    private static func file(agent: String, harness: AgentRegistration.Harness?) -> URL? {
        let registry = AgentRegistry(directory: AgentHost.registryDirectory())
        if let own = registry.icon(agent: agent) { return own }
        guard let harness = harness ?? (try? registry.load(agent: agent).get())?.registration.harness else {
            return nil
        }
        let url = AgentRegistry.defaultIcon(harness: harness, marks: directory)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func sparkle(_ agent: String) -> NSImage? {
        NSImage(systemSymbolName: "sparkle", accessibilityDescription: agent)
    }
}
