import AppKit
import ParrotCore
import SiriusProtocol

// A debug path for reviewing the pill's release without dictating:
// `Sirius --dictation-snapshots <dir>` drives the pill through a hold off
// every screen, with the Debug slow motion at 10x, and renders it at 2x at
// a few moments, from the bars through the shrink into the sparkle, its
// breath and the close, then a failure's red exit, then a new hold inside
// each exit and an earlier transcript ending during a hold, then the open
// on an agent's logo and the real-speed runs from press to exit, to
// <dir>/<name>.png,
// then exits before the socket server starts, as LaunchSnapshots does. These are the live animation
// caught mid-flight, not poses, so a moment can land a frame either side;
// the pill's curve does most of its travel early, so the mid-shrink and
// closing shots come soon after their cue.
@MainActor
enum DictationSnapshots {
    static let flag = "--dictation-snapshots"

    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return }
        let directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        SpatialMotion.timeScale = 10
        let pill = DictationPill(mark: NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Sirius"))
        pill.parksOffscreen = true

        func run(_ seconds: TimeInterval, levels: Bool = false) {
            let end = Date().addingTimeInterval(seconds)
            let start = ProcessInfo.processInfo.systemUptime
            while Date() < end {
                if levels {
                    let t = ProcessInfo.processInfo.systemUptime - start
                    pill.level(Float(0.004 + 0.06 * (0.5 + 0.5 * sin(2 * .pi * 0.5 * t))))
                }
                RunLoop.main.run(until: Date().addingTimeInterval(0.012))
            }
        }
        func shoot(_ name: String) {
            guard let view = pill.snapshotView, let image = LaunchSnapshots.render(view) else {
                FileManager.default.createFile(atPath: directory.path + "/FAILED-\(name)", contents: nil)
                return
            }
            let url = directory.appendingPathComponent("\(name).png")
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
            print(url.path)
        }

        let shrink = DictationPill.scaleDuration
        pill.dictationStarted()
        run(DictationPill.markHold + shrink + 1, levels: true)
        shoot("1-recording")
        pill.dictationTranscribing()
        run(shrink * 0.03)
        shoot("2-release")
        run(shrink * 0.07)
        shoot("3-mid-shrink")
        run(shrink * 1)
        shoot("4-sparkle")
        run(TranscribingSparkle.period / 2)
        shoot("5-breath-dim")
        run(TranscribingSparkle.period / 2)
        shoot("6-breath-full")
        pill.dictationFinished()
        run(shrink * 0.07)
        shoot("7-closing")
        run(shrink * 1.2)
        shoot("8-out")

        // A failed transcription: red, the shake, the hold and the fade.
        pill.dictationStarted()
        run(DictationPill.markHold + shrink + 1, levels: true)
        pill.dictationTranscribing()
        run(shrink * 1.2)
        shoot("9-error-sparkle")
        pill.dictationFailed()
        let shake = DictationPill.baseShakeDuration * SpatialMotion.timeScale
        run(shake / 12)
        shoot("10-error-shake-right")
        run(shake / 6)
        shoot("11-error-shake-left")
        run(DictationPill.errorHold - shake / 4)
        shoot("12-error-held")
        run(DictationPill.fadeDuration / 2)
        shoot("13-error-fading")
        run(DictationPill.fadeDuration)
        shoot("14-error-out")

        // A fast hand: a new hold inside the close's shrink, then
        // inside a failure's red, opens a fresh pill at once; the hold
        // before's transcript ending during a new hold leaves its bars up.
        pill.dictationStarted()
        run(DictationPill.markHold + shrink + 1, levels: true)
        pill.dictationTranscribing()
        pill.dictationFinished()
        run(DictationPill.transcribingHold + shrink * 0.2)
        shoot("15-closing")
        pill.dictationStarted()
        run(DictationPill.markHold + shrink + 1, levels: true)
        shoot("16-rehold-during-close")
        pill.dictationTranscribing()
        run(shrink * 1.2)
        pill.dictationFailed()
        run(DictationPill.errorHold / 2)
        shoot("17-error-red")
        pill.dictationStarted()
        run(shrink * 0.5)
        shoot("18-rehold-during-error")
        run(DictationPill.markHold + shrink + 1, levels: true)
        shoot("19-rehold-recording")
        pill.dictationTranscribing()
        run(shrink * 0.2)
        pill.dictationStarted()
        run(DictationPill.markHold + shrink, levels: true)
        pill.dictationFinished()
        run(shrink * 2, levels: true)
        shoot("20-earlier-ends-during-hold")
        run(DictationPill.transcribingHold + shrink * 2)

        // The pill opens on the logo of the agent the hold is
        // going to, in its own colours; a paste opens on the mark; a late ⌃
        // crosses the logo back to the mark; from the release on it is the
        // blue sparkle, a release during the open crossing the logo into it.
        func logo(_ agent: String, _ harness: AgentRegistration.Harness) -> NSImage? {
            AgentMarks.mark(agent: agent, harness: harness).flatMap { $0.isTemplate ? nil : $0 }
        }
        let claude = logo("claude", .claudeCode)
        let codex = logo("codex", .codex)
        if claude == nil { FileManager.default.createFile(atPath: directory.path + "/FAILED-claude-logo", contents: nil) }
        if codex == nil { FileManager.default.createFile(atPath: directory.path + "/FAILED-codex-logo", contents: nil) }
        func press(_ target: NSImage?, pastes: Bool = false) {
            pill.pastes = pastes
            pill.destination = { target }
            pill.dictationStarted()
        }
        func finish() {
            pill.dictationFinished()
            run(DictationPill.transcribingHold + shrink * 2)
        }
        press(claude)
        run(shrink * 0.8)
        shoot("21-claude-open")
        run(DictationPill.markHold + 1, levels: true)
        shoot("22-claude-recording")
        pill.dictationTranscribing()
        run(shrink * 1.2)
        shoot("23-claude-released-sparkle")
        finish()
        press(codex)
        run(shrink * 0.3)
        shoot("24-codex-open")
        pill.pastes = true
        run(DictationPill.logoSwap / 2)
        shoot("25-late-paste-crossing")
        run(DictationPill.logoSwap * 0.6)
        shoot("26-late-paste-mark")
        pill.dictationFailed(DictationError.cancelled)
        run(shrink * 2)
        press(nil, pastes: true)
        run(shrink * 0.8)
        shoot("27-paste-open")
        pill.dictationFailed(DictationError.cancelled)
        run(shrink * 2)
        pill.pastes = false
        press(claude)
        run(shrink * 0.5)
        pill.dictationTranscribing()
        run(shrink * 0.1)
        shoot("28-release-during-open-crossing")
        run(shrink * 1.2)
        shoot("29-release-during-open-sparkle")
        finish()
        press(claude)
        run(DictationPill.markHold + shrink + 1, levels: true)
        pill.dictationTranscribing()
        run(shrink * 1.2)
        pill.dictationFailed()
        run(DictationPill.errorHold / 2)
        shoot("30-error-red")
        run(DictationPill.errorHold + DictationPill.fadeDuration + shrink * 2)

        // At real speed, a frame every 1/30 s from the press until the bars
        // have landed, then from the release to the pill gone: a fast
        // transcript (0.1 s), a slow one (3 s), a paste, and a release
        // during the open; checked frame by frame for a jump.
        SpatialMotion.timeScale = 1
        func sequence(_ name: String, transcript: TimeInterval, to target: NSImage?, pastes: Bool = false,
                      held: TimeInterval? = nil) {
            press(target, pastes: pastes)
            let pressed = ProcessInfo.processInfo.systemUptime
            let opens = held ?? DictationPill.markHold + DictationPill.scaleDuration
            var opening = 0
            while ProcessInfo.processInfo.systemUptime - pressed < opens {
                let t = ProcessInfo.processInfo.systemUptime - pressed
                shoot(String(format: "%@-open-%03d-%04dms", name, opening, Int(t * 1000)))
                opening += 1
                run(1.0 / 30, levels: true)
            }
            if held == nil { run(0.5, levels: true) }
            pill.dictationTranscribing()
            let start = ProcessInfo.processInfo.systemUptime
            var delivered = false
            var frame = 0
            while true {
                let t = ProcessInfo.processInfo.systemUptime - start
                if !delivered, t >= transcript {
                    delivered = true
                    pill.dictationFinished()
                }
                if delivered, !pill.isOrderedIn { break }
                shoot(String(format: "%@-%03d-%04dms", name, frame, Int(t * 1000)))
                frame += 1
                run(1.0 / 30)
            }
        }
        sequence("rt-fast", transcript: 0.1, to: claude)
        sequence("rt-slow", transcript: 3, to: claude)
        sequence("rt-paste", transcript: 0.1, to: nil, pastes: true)
        pill.pastes = false
        sequence("rt-quick", transcript: 0.1, to: codex, held: 0.2)
        exit(0)
    }
}
