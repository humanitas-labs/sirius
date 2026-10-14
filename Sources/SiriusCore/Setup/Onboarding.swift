import Foundation

// The first-run onboarding's steps and when it opens, with no AppKit: the
// app's OnboardingWindow is the view. After Parrot's Onboarding
// (parrot Sources/ParrotApp/App/Onboarding.swift), as a step flow. Four
// pages, as the design's frames have them: the welcome is a preface, then three steps with dots.
public enum OnboardingStep: Int, CaseIterable, Equatable, Sendable {
    // The star, the wordmark and the tagline. No dots: it comes before
    // step 1.
    case welcome
    // Claude and ChatGPT (Codex), a folder each.
    case agents
    // Microphone and Accessibility, each with its own Allow pill.
    case permissions
    // The two ways in, and the guided first turn.
    case done

    public var next: OnboardingStep? { OnboardingStep(rawValue: rawValue + 1) }
    public var previous: OnboardingStep? { OnboardingStep(rawValue: rawValue - 1) }

    // The steps the dots stand for: all but the welcome.
    public static let dotted: [OnboardingStep] = allCases.filter { $0.dot != nil }

    // The step's dot, from 0, or nil for the welcome, which shows none.
    public var dot: Int? { self == .welcome ? nil : rawValue - 1 }
}

public enum Onboarding {
    // UserDefaults' key for the window having been through: set by the
    // first turn, Skip, or closing the window by hand, as Parrot's
    // `onboarding.completed`.
    public static let completedKey = "onboarding.completed"

    // Whether the window opens at launch: until it has been through once,
    // and whenever no agent is registered, since Sirius does nothing
    // without one. An install from before the onboarding sees it once.
    public static func showsWindow(hasAgents: Bool, completed: Bool) -> Bool {
        !hasAgents || !completed
    }

    // Whether the user can move on from `step`. The agents step needs one
    // agent chosen with its folder; the grants never hold the user up,
    // since dictation can be set up later.
    public static func canContinue(from step: OnboardingStep, agentsChosen: Int) -> Bool {
        switch step {
        case .agents: agentsChosen > 0
        case .welcome, .permissions, .done: true
        }
    }
}

// The welcome moves on to the agents by itself: the
// lockup comes in, holds, and the page crossfades to the next, about 3.2 s
// from opening; with Reduce Motion the lockup fades in and holds as long.
// Only when the window opens at the welcome, and only from it. Before
// fcd9e7d the opening ran on into the agents' marks on one page; the
// split into four pages left the welcome waiting for →.
public enum WelcomeTiming {
    // Before the lockup starts, so the window is up and drawn.
    public static let delay = 0.15
    // The lockup's blur-in, or its plain fade under Reduce Motion.
    public static let reveal = 1.2
    public static let fade = 0.6
    // How long the lockup holds once in.
    public static let hold = 1.8

    // From opening to moving on.
    public static func advance(reduceMotion: Bool) -> TimeInterval {
        delay + (reduceMotion ? fade : reveal) + hold
    }
}

// The last page's guided first turn (frames A to E), with no
// AppKit: OnboardingWindow drives it, and E, the dissolve, is the window's.
public enum FirstTurn: Equatable, Sendable {
    // A: waiting for fn.
    case ready
    // B: fn held, then the transcription.
    case listening
    // C: the transcript sent to the agent named, its reply awaited.
    case answering(transcript: String, agent: String)
    // D: the reply has landed, or the wait ran out; the composer's shortcut
    // is taught, and its opening ends the onboarding.
    case composing

    // Whether the next dictated message is the first turn: A and B.
    public var takesMessage: Bool { self == .ready || self == .listening }

    // C's reply, or the end of its wait: D. Elsewhere nothing changes.
    public var replied: FirstTurn {
        if case .answering = self { return .composing }
        return self
    }

    // The rows dim to 35% from B; in D the Compose row comes back, so the
    // eye goes to its shortcut.
    public static let dimmed = 0.35
    public var holdRowOpacity: Double { self == .ready ? 1 : Self.dimmed }
    public var composeRowOpacity: Double { self == .ready || self == .composing ? 1 : Self.dimmed }

    // Whether a row's shortcut takes clicks: both in A, Compose's in D too,
    // so it can still be rebound there.
    public var holdRowEnabled: Bool { self == .ready }
    public var composeRowEnabled: Bool { self == .ready || self == .composing }
}
