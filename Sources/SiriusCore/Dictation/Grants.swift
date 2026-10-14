import Foundation

// The two grants dictation needs and what each Allow button does, with no
// AppKit: the app's Permissions reads the system and performs the steps.
// Sirius never shows a system prompt unannounced: a prompt appears only
// from its own Allow button, and never while the other one is up, so the
// two never stack, as in Parrot's onboarding.

// The microphone grant as setup shows it.
public enum MicrophoneGrant: Equatable, Sendable {
    case granted
    // The system has never asked; a request shows its prompt.
    case notDetermined
    // Denied or restricted: only System Settings can change it.
    case denied
}

// Both grants, read at one moment.
public struct GrantState: Equatable, Sendable {
    public var accessibility: Bool
    public var microphone: MicrophoneGrant

    public init(accessibility: Bool, microphone: MicrophoneGrant) {
        self.accessibility = accessibility
        self.microphone = microphone
    }

    public var allGranted: Bool { accessibility && microphone == .granted }
}

public enum Grant: CaseIterable, Equatable, Sendable {
    // The fn tap.
    case accessibility
    case microphone
}

// One thing an Allow button does.
public enum GrantStep: Equatable, Sendable {
    // AXIsProcessTrustedWithOptions with the prompt, which also lists Sirius
    // in the Accessibility pane.
    case promptAccessibility
    case openAccessibilitySettings
    case requestMicrophone
    case openMicrophoneSettings
}

// What the app knows besides the grants themselves.
public struct GrantContext: Equatable, Sendable {
    // The bundle has NSMicrophoneUsageDescription. Without it a microphone
    // request crashes the process, so the request is withheld.
    public var canRequestMicrophone: Bool
    // The Accessibility prompt has been shown by this process already; a
    // second press opens the pane instead of asking again.
    public var accessibilityPrompted: Bool
    // A system prompt from an Allow button is still up: both buttons wait
    // until it is answered, so the two prompts never stack.
    public var prompting: Grant?

    public init(canRequestMicrophone: Bool, accessibilityPrompted: Bool = false, prompting: Grant? = nil) {
        self.canRequestMicrophone = canRequestMicrophone
        self.accessibilityPrompted = accessibilityPrompted
        self.prompting = prompting
    }
}

public enum Grants {
    public static func isGranted(_ grant: Grant, in state: GrantState) -> Bool {
        switch grant {
        case .accessibility: state.accessibility
        case .microphone: state.microphone == .granted
        }
    }

    // What Allow does for `grant`: nothing once granted; the system prompt
    // the first time, then its System Settings pane. Nothing while the other
    // prompt is up, and no microphone request without the plist key.
    public static func allowSteps(for grant: Grant, in state: GrantState, context: GrantContext) -> [GrantStep] {
        if isGranted(grant, in: state) { return [] }
        if context.prompting != nil { return [] }
        switch grant {
        case .accessibility:
            return context.accessibilityPrompted ? [.openAccessibilitySettings] : [.promptAccessibility]
        case .microphone:
            switch state.microphone {
            case .granted: return []
            case .notDetermined: return context.canRequestMicrophone ? [.requestMicrophone] : []
            case .denied: return [.openMicrophoneSettings]
            }
        }
    }

    // Whether `steps` show a system prompt, which then holds both buttons
    // until it is answered.
    public static func prompts(_ steps: [GrantStep]) -> Bool {
        steps.contains { $0 == .promptAccessibility || $0 == .requestMicrophone }
    }
}
