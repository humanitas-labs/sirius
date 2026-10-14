import Foundation
import SiriusCore
import SiriusProtocol
import UserNotifications

// Hands notify calls to Notification Center. The receipt means handed over,
// not shown: the user may have notifications off for Sirius, and Notification
// Center does its own stacking.
@MainActor
final class NotificationPresenter {
    private enum Authorization {
        // Not yet asked this run. The first notify asks, never launch.
        case unresolved
        // The prompt is up; requests wait for the answer.
        case requesting
        // The user answered, now or in an earlier run. Later changes in
        // System Settings take effect without asking again, so add is always
        // tried and a refusal shows up as its error.
        case resolved
    }

    private var center: UNUserNotificationCenter?
    private let banner = ForegroundBanner()
    private var authorization = Authorization.unresolved
    private var waiting: [UNNotificationRequest] = []
    private var loggedRefusal = false

    // UNUserNotificationCenter.current() raises outside an app bundle
    // (swift run, .build/debug/SiriusApp), so it is never touched there.
    static var isBundled: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    // False only when the app runs without a bundle; the caller answers
    // INTERNAL_ERROR. Never waits on the permission prompt: a request made
    // while the prompt is up is held and added once the user answers.
    func post(title: String, body: String) -> Bool {
        guard let center = resolveCenter() else { return false }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)

        switch authorization {
        case .resolved:
            add(request, to: center)
        case .requesting:
            hold(request)
        case .unresolved:
            hold(request)
            authorization = .requesting
            Task { await self.authorize(center) }
        }
        return true
    }

    private func resolveCenter() -> UNUserNotificationCenter? {
        if let center { return center }
        guard Self.isBundled else { return nil }
        let center = UNUserNotificationCenter.current()
        center.delegate = banner
        self.center = center
        return center
    }

    private func authorize(_ center: UNUserNotificationCenter) async {
        let status = await center.notificationSettings().authorizationStatus
        var allowed = status != .denied
        if status == .notDetermined {
            // Throws when the user closes the prompt; that is a refusal too.
            allowed = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        }
        // While refused, add succeeds and the system drops the notification,
        // so this is the only point where a refusal is visible.
        if !allowed { refused() }
        authorization = .resolved
        let held = waiting
        waiting = []
        for request in held { add(request, to: center) }
    }

    // Bounded like the toast queue, so an unanswered prompt cannot grow it
    // without limit; the oldest goes first.
    private func hold(_ request: UNNotificationRequest) {
        if waiting.count >= Limits.maxQueued { waiting.removeFirst() }
        waiting.append(request)
    }

    private func add(_ request: UNNotificationRequest, to center: UNUserNotificationCenter) {
        center.add(request) { error in
            guard let error else { return }
            Task { @MainActor in self.log("notification not added: \(error.localizedDescription)") }
        }
    }

    // Denied permission still returns a receipt; say so once on stderr.
    private func refused() {
        guard !loggedRefusal else { return }
        loggedRefusal = true
        log("notifications are off for Sirius; allow them in System Settings > Notifications")
    }

    private func log(_ message: String) {
        SiriusLog.notifications.info(message)
    }
}

// Sirius is an accessory app, so it is rarely frontmost, but when it is the
// system would otherwise drop the banner. Clicks need no handling yet.
private final class ForegroundBanner: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
