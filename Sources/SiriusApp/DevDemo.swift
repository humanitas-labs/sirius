import Foundation
import SiriusCore
import SiriusProtocol

// SIRIUS_DEMO=1: three toasts from "dev" at launch, the second an alert,
// through the same accept path the socket server uses. For iterating on the
// toast look without a running agent.
// The toast transition cases: lines A–M and sequences 1–13, played from
// the menu-bar menu's Debug items (Option-click), or SIRIUS_DEMO=<number>
// at launch.
@MainActor
enum DevDemo {
    static let basic = [
        "Pushed the branch; tests pass.",
        "The deploy is waiting on your approval in the release channel.",
        "Cleaned up 14 stale worktrees.",
    ]

    static let lines: [Character: String] = {
        let h = "Your calendar is clear from 2 to 5 today. The only fixed thing is the weekly standup at 5:30, and Jordan moved tomorrow's call to 11. I'd use the block for the landing page copy, since that's the item gating Monday's release and it needs a clear head."
        return [
            "A": "On it.",
            "B": "Done.",
            "C": "Opened 138 at the ideas table.",
            "D": "Sent to Linear as ENG-142, assigned to you, due Monday.",
            "L": "https://github.com/humanitas-labs/sirius/pull/42",
            "E": "The build finished in 41 s. Tests passed (94/94), and the new version is installed; relaunch Sirius to pick it up.",
            "F": "Codex is still working on the parser. I've queued your request behind it and will start as soon as it finishes, in about a minute.",
            "G": "No, we never set one up. tmux has only shell, notes and docs. I now think your earlier 'tmo' meant tmux. Want a heron window in code/projects/heron, with a Claude session running in it?",
            "H": h,
            // H and a question, to the 280-character cap.
            "M": h + " Want me to block it? Say go.",
        ]
    }()

    // A step: wait `after` seconds from the step before, then do it.
    enum Step {
        case toast(Character)
        case openComposer
        case closeComposer
    }

    static let sequences: [(name: String, steps: [(after: TimeInterval, step: Step)])] = [
        ("A → C, one line, width only", [(0, .toast("A")), (0, .toast("C"))]),
        ("C → A, one line, shrinking", [(0, .toast("C")), (0, .toast("A"))]),
        ("A → D, one line to the cap", [(0, .toast("A")), (0, .toast("D"))]),
        ("D → E, one line to two", [(0, .toast("D")), (0, .toast("E"))]),
        ("A → G, pill to three lines", [(0, .toast("A")), (0, .toast("G"))]),
        ("G → A, three lines to pill", [(0, .toast("G")), (0, .toast("A"))]),
        ("E → F, two lines, small width change", [(0, .toast("E")), (0, .toast("F"))]),
        ("F → H → M, growing at the cap", [(0, .toast("F")), (0, .toast("H")), (0, .toast("M"))]),
        ("M → B, the maximum to the minimum", [(0, .toast("M")), (0, .toast("B"))]),
        ("L, an unbreakable URL", [(0, .toast("L"))]),
        ("A, C, E, A within 1 s", [(0, .toast("A")), (0.3, .toast("C")), (0.3, .toast("E")), (0.3, .toast("A"))]),
        ("E arrives mid-open", [(0, .openComposer), (0.1, .toast("E"))]),
        ("C → E with the composer open, then closed",
         [(0, .toast("C")), (1, .openComposer), (0, .toast("E")), (4.5, .closeComposer)]),
    ]

    static var openComposer: () -> Void = {}
    static var closeComposer: () -> Void = {}
    private static var nextID: Int64 = 1

    static func runIfRequested(queue: CommandQueue) {
        switch ProcessInfo.processInfo.environment["SIRIUS_DEMO"] {
        case "1":
            Task { for text in basic { await toast(text, queue: queue) } }
        case let value?:
            if let number = Int(value) { play(number, queue: queue) }
        case nil:
            break
        }
    }

    // Plays sequence `number` (1-based). Queued toasts keep their linger, so
    // each swap comes when the one before has had its time.
    static func play(_ number: Int, queue: CommandQueue) {
        guard sequences.indices.contains(number - 1) else { return }
        Task {
            for (after, step) in sequences[number - 1].steps {
                if after > 0 { try? await Task.sleep(for: .seconds(after)) }
                switch step {
                case .toast(let id): await toast(lines[id] ?? "", queue: queue)
                case .openComposer: openComposer()
                case .closeComposer: closeComposer()
                }
            }
        }
    }

    private static func toast(_ text: String, queue: CommandQueue) async {
        let command = Command(agent: devAgent, id: .number(nextID),
                              call: .display(DisplayParams(kind: .toast, content: [.text(TextContent(text: text))])))
        nextID += 1
        _ = await queue.accept(command)
    }
}
