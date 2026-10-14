// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "sirius",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        // ParrotCore, the dictation engine: capture, the fn gesture,
        // WhisperKit transcription, the dictionary and the loop. Pinned by
        // revision, Parrot's develop with the loop's public API, until
        // Parrot's next release tag.
        .package(url: "https://github.com/humanitas-labs/parrot.git",
                 revision: "f577918537f7ba901417b3f8a43040a62804fae5"),
        // In-app updates, as Parrot's: the version Parrot resolves.
        // A binary framework: scripts/build-app.sh embeds it in
        // Sirius.app/Contents/Frameworks and signs it inside-out.
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.10.0"),
    ],
    targets: [
        // The wire contract and nothing else: requests, results, errors,
        // content blocks, the registration, validation. No IO. The Swift
        // reference for docs/protocol/proto.ts.
        .target(name: "SiriusProtocol"),
        // The socket client both helpers share: connect to $SIRIUS_SOCKET,
        // write one frame, read one, map the outcome.
        .target(name: "SiriusClient", dependencies: ["SiriusProtocol"]),
        // Registry, log, socket server, queue.
        .target(name: "SiriusCore", dependencies: ["SiriusProtocol"]),
        // One file per adapter: start, resume, deliver, turn end, stop.
        .target(name: "SiriusAdapters", dependencies: ["SiriusCore"]),
        // Sirius.app: composer, presenter, setup. scripts/build-app.sh
        // installs it as Contents/MacOS/Sirius. Named SiriusApp because a
        // `Sirius` product would collide with `sirius` on a case-insensitive
        // volume.
        .executableTarget(
            name: "SiriusApp",
            dependencies: [
                "SiriusCore",
                "SiriusAdapters",
                .product(name: "ParrotCore", package: "parrot"),
                .product(name: "Sparkle", package: "Sparkle"),
            ]
        ),
        // The CLI helper the agents run from their shell. No AppKit, no Core.
        .executableTarget(
            name: "sirius",
            dependencies: [
                "SiriusProtocol",
                "SiriusClient",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        // The MCP helper, for agents whose sandbox blocks the CLI's socket
        // connect (Codex).
        .executableTarget(
            name: "sirius-mcp",
            dependencies: ["SiriusProtocol", "SiriusClient"]
        ),
        .testTarget(name: "SiriusProtocolTests", dependencies: ["SiriusProtocol"]),
        .testTarget(name: "SiriusClientTests", dependencies: ["SiriusClient"]),
        .testTarget(name: "SiriusCoreTests", dependencies: ["SiriusCore"]),
        .testTarget(name: "SiriusAdaptersTests", dependencies: ["SiriusAdapters", "SiriusClient"]),
        // The app's own logic that needs AppKit: the shortcut recording,
        // the menu. Nothing here registers a real hot key.
        .testTarget(name: "SiriusAppTests", dependencies: ["SiriusApp", "SiriusCore", "SiriusProtocol"]),
    ]
)
