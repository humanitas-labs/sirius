import AppKit
import SiriusAdapters
import SiriusCore
import SiriusProtocol
import SwiftUI

// A debug path for reviewing the onboarding against its design frames
// without opening a window, touching the running Sirius or asking for any
// grant: `Sirius --onboarding-snapshots <dir>` renders each page at 2x to
// <dir>/<n>-<name>.png and exits before the socket server starts. The
// grants are simulated (GrantsModel.simulate), never read from or asked of
// the system; the agents are the detector's, with no folders chosen.
@MainActor
enum OnboardingSnapshots {
    static let flag = "--onboarding-snapshots"

    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return }
        let directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for shot in shots {
            let model = OnboardingModel.preview(step: shot.step)
            shot.prepare(model)
            model.intro.finish()
            let content = OnboardingWindow.surface(around: OnboardingView(model: model))
            let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000),
                                                      size: OnboardingWindow.size),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = content
            window.backgroundColor = .clear
            window.isOpaque = false
            window.orderFrontRegardless()
            content.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { continue }
            content.cacheDisplay(in: content.bounds, to: bitmap)
            window.orderOut(nil)
            guard let image = bitmap.cgImage else {
                FileManager.default.createFile(atPath: directory.path + "/FAILED-\(shot.name)", contents: nil)
                continue
            }
            let rep = NSBitmapImageRep(cgImage: image)
            let url = directory.appendingPathComponent("\(shot.name).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            print(url.path)
        }
        exit(0)
    }

    private struct Shot {
        let name: String
        let step: OnboardingStep
        var prepare: @MainActor (OnboardingModel) -> Void = { _ in }
    }

    private static var shots: [Shot] {
        OnboardingStep.allCases.enumerated().map { index, step in
            Shot(name: "\(index + 1)-\(step)", step: step) { model in
                model.grants.simulate(GrantState(accessibility: false, microphone: .notDetermined))
            }
        } + [
            Shot(name: "3b-permissions-granted", step: .permissions) { model in
                model.grants.simulate(GrantState(accessibility: true, microphone: .granted))
            },
            Shot(name: "4b-done-listening", step: .done) { model in
                model.grants.simulate(GrantState(accessibility: true, microphone: .granted))
                model.firstTurn = .listening
            },
            Shot(name: "4d-done-recording", step: .done) { model in
                model.grants.simulate(GrantState(accessibility: true, microphone: .granted))
                model.shortcuts.simulate(.recording(hint: nil))
            },
            Shot(name: "4e-done-taken", step: .done) { model in
                model.grants.simulate(GrantState(accessibility: true, microphone: .granted))
                model.shortcuts.simulate(.refused("Taken by macOS"))
            },
            Shot(name: "4c-done-answering", step: .done) { model in
                model.grants.simulate(GrantState(accessibility: true, microphone: .granted))
                model.firstTurn = .answering(transcript: "Hello, what can you do?", agent: "Claude")
            },
            Shot(name: "4f-done-compose", step: .done) { model in
                model.grants.simulate(GrantState(accessibility: true, microphone: .granted))
                model.firstTurn = .composing
            },
        ]
    }
}

extension OnboardingModel {
    // A model for the snapshots: both harnesses found, no folder chosen.
    static func preview(step: OnboardingStep) -> OnboardingModel {
        let agents = AgentRegistration.Harness.allCases.map { harness in
            AgentChoice(harness: harness, current: nil, detector: AgentDetector())
        }
        for agent in agents { agent.simulateFound("/usr/local/bin/\(AgentDetector.command(for: agent.harness))") }
        return OnboardingModel(step: step, agents: agents,
                               shortcuts: ShortcutsModel(compose: .compose, holdKey: .fn))
    }
}
