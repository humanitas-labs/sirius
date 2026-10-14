import Foundation
import SiriusCore
import SiriusProtocol

// The repo's instruction templates (packaging/agent), which build-app.sh
// puts in Sirius.app/Contents/Resources/agent.
enum InstructionsTemplates {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("packaging/agent", isDirectory: true)

    // What a newly set-up agent of this harness is given.
    static func seeded(_ harness: AgentRegistration.Harness) throws -> String {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("sirius-instructions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Instructions.seed(folder: folder, template: directory.appendingPathComponent(Instructions.entrypoint),
                              harness: directory.appendingPathComponent(harness.rawValue, isDirectory: true))
        return try Instructions.compose(entrypoint: folder.appendingPathComponent(Instructions.entrypoint)) ?? ""
    }
}
