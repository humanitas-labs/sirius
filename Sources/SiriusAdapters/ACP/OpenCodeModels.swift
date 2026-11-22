import Foundation
import SiriusProtocol

// The models one user's OpenCode actually offers, for setup's Model menu.
// OpenCode's models are the user's own — whichever providers their account
// and config enable — so no fixed list can ship the way Claude's and
// Codex's do, and `opencode models` lists every model of every provider
// (589 here). What the agent's own session takes is the enabled list in
// session/new's config options, and that is what this reads: a throwaway
// ACP session, asked the same way the adapter asks, deleted before the
// probe ends so nothing is left in the user's session list.
//
// `directory` is where the session is opened: the agent's workspace when
// one is known, else the home folder, since OpenCode reads its config per
// directory. One timeout covers the whole probe; any failure answers nil
// and the Model menu falls back to Default and a hand-written id.
public enum OpenCodeModels {
    // One offered model: the id the session's config takes, and the name
    // it shows.
    public struct Offered: Equatable, Sendable {
        public var id: String
        public var name: String?

        public init(id: String, name: String? = nil) {
            self.id = id
            self.name = name
        }
    }

    public static func offered(executable: URL, directory: URL,
                               environment: [String: String] = ProcessInfo.processInfo.environment,
                               timeout: Duration = .seconds(15)) async -> [Offered]? {
        let connection = JSONRPCStdio(name: "opencode acp", executable: executable, arguments: ["acp"],
                                      environment: environment, directory: directory)
        do {
            try connection.launch()
        } catch {
            return nil
        }
        return await withTaskGroup(of: [Offered]?.self) { group in
            group.addTask { await readModels(on: connection, in: directory) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return nil }
                await connection.terminate()
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            await connection.terminate()
            return first
        }
    }

    // initialize, session/new, read the model config option, delete the
    // session. Whatever step fails answers nil.
    private static func readModels(on connection: JSONRPCStdio, in directory: URL) async -> [Offered]? {
        do {
            let initialized = try await connection.request("initialize", .object([
                "protocolVersion": .number(Double(ACPAdapter.protocolVersion)),
                "clientCapabilities": .object([
                    "fs": .object(["readTextFile": .bool(false), "writeTextFile": .bool(false)]),
                    "terminal": .bool(false),
                ]),
                "clientInfo": .object(["name": .string("sirius"), "title": .string("Sirius"),
                                       "version": .string(ACPAdapter.clientVersion)]),
            ]))
            guard initialized["protocolVersion"]?.safeInteger == ACPAdapter.protocolVersion else { return nil }
            let opened = try await connection.request("session/new", .object([
                "cwd": .string(directory.path),
                "mcpServers": .array([]),
            ]))
            if let session = opened["sessionId"]?.string {
                // The session was only opened to read its options; take it
                // out again, and go on even where a version can't.
                _ = try? await connection.request("session/delete", .object(["sessionId": .string(session)]))
            }
            guard let option = ACPConfig.option(in: opened["configOptions"]?.array ?? [], category: "model")
            else { return nil }
            var offered = ACPConfig.entries(of: option).map { Offered(id: $0.value, name: $0.name) }
            // The session's current default first — the one the account is
            // set to, and the likeliest pick — then the rest in the
            // session's order.
            if let current = option["currentValue"]?.string,
               let index = offered.firstIndex(where: { $0.id == current }) {
                offered.insert(offered.remove(at: index), at: 0)
            }
            return offered
        } catch {
            return nil
        }
    }
}
