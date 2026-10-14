import AppKit
import ApplicationServices
import AVFoundation
import SiriusCore

// Reading and asking for Accessibility and Microphone, after Parrot's
// App/Permissions.swift. Reading never prompts; only perform(_:) does, and
// only from an Allow button in setup. What each button does is decided in
// SiriusCore's Grants, which is tested.
@MainActor
enum Permissions {
    // The Accessibility prompt has been shown by this process; the next
    // Allow opens the pane instead (Grants.allowSteps).
    private(set) static var accessibilityPrompted = false

    // This process's grants now.
    static var current: GrantState {
        GrantState(accessibility: AXIsProcessTrusted(), microphone: microphone)
    }

    static var microphone: MicrophoneGrant {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    // Requesting the microphone without NSMicrophoneUsageDescription in the
    // bundle's Info.plist kills the process, so the request waits for it
    // (build-app.sh's Info.plist has the key), and a bare `swift run` never requests.
    static var canRequestMicrophone: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil
    }

    // Runs one step. `answered` runs on the main actor once a microphone
    // request has its answer; the Accessibility prompt reports nothing, so
    // the caller watches for the grant instead.
    static func perform(_ step: GrantStep, answered: @escaping @MainActor () -> Void = {}) {
        switch step {
        case .promptAccessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            accessibilityPrompted = true
            _ = AXIsProcessTrustedWithOptions(options)
        case .openAccessibilitySettings:
            openSettings(pane: "Privacy_Accessibility")
        case .requestMicrophone:
            // Guarded twice: Grants withholds the step without the key too.
            guard canRequestMicrophone, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else {
                return answered()
            }
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { answered() } }
            }
        case .openMicrophoneSettings:
            openSettings(pane: "Privacy_Microphone")
        }
    }

    // Opens System Settings → Privacy & Security at `pane`.
    static func openSettings(pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}
