import AppKit

// Whether Parrot.app is running, and when that changes. Sirius owns fn
// regardless and Parrot is being retired; while it
// runs, setup asks the user to quit it so a press isn't handled twice.
@MainActor
final class ParrotPresence {
    nonisolated static let bundleID = "com.humanitas.parrot"

    private(set) var isRunning: Bool
    // Called with the new value on each launch or quit of Parrot.
    var onChange: ((Bool) -> Void)?

    private var observers: [NSObjectProtocol] = []

    init() {
        isRunning = Self.running()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == Self.bundleID else { return }
                MainActor.assumeIsolated { self?.update() }
            })
        }
    }

    // Removes the observers; call before dropping the last reference.
    func stop() {
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers = []
        onChange = nil
    }

    private func update() {
        let now = Self.running()
        guard now != isRunning else { return }
        isRunning = now
        onChange?(now)
    }

    // A terminating instance can still be listed for a moment after its
    // terminate notification, so it does not count.
    private static func running() -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains { !$0.isTerminated }
    }
}
