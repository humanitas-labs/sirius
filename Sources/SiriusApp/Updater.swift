import AppKit
import Foundation
import Sparkle
import SiriusCore

// In-app updates through Sparkle, as Parrot's Updater.
//
// Sparkle reads its configuration from Info.plist: `SUFeedURL` (the
// appcast.xml asset of the latest GitHub release), `SUPublicEDKey` (updates
// and the feed must be signed with the matching private key, which lives
// only in the release Mac's keychain under the account "sirius"), and a
// daily automatic check. An update replaces Sirius.app in place and
// relaunches it; the Developer ID identity does not change, so the
// microphone and notification grants carry over. The helpers live in the
// bundle, so they update with the app.
@MainActor
enum Updater {
    private static var controller: SPUStandardUpdaterController?
    private static let reminders = UpdateReminders()
    private static let localCheck = LocalCheck()

    // True once Sparkle started. The menu shows "Check for Updates…" only then.
    static var isRunning: Bool { controller != nil }

    // Starts Sparkle's scheduled checks. Does nothing, with one log line,
    // when the bundle can't update itself.
    static func start(bundle: Bundle = .main) {
        guard controller == nil else { return }
        if let problem = configurationProblem(info: bundle.infoDictionary ?? [:]) {
            SiriusLog.app.info("updates off: \(problem)")
            return
        }
        // Started by hand rather than by the controller, which reports a
        // failed start in a modal alert; a log line is enough here.
        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: reminders
        )
        do {
            try controller.updater.start()
        } catch {
            SiriusLog.app.error("updates off: Sparkle didn't start: \(error.localizedDescription)")
            return
        }
        self.controller = controller
        SiriusLog.app.info("updates on: checking \(controller.updater.feedURL?.absoluteString ?? "?") "
            + "every \(Int(controller.updater.updateCheckInterval / 3600))h")
    }

    // "Check for Updates…" from the menu.
    static func checkForUpdates() {
        guard let controller else { return }
        // An accessory app is never frontmost; without this the update
        // window can open behind the app the user is in.
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    // `Sirius --check-for-updates`, for the end-to-end update test only: a
    // test build whose SUFeedURL is a loopback http feed checks once,
    // downloads and installs what it finds without asking, and relaunches.
    // It runs before the socket server, so it works beside an installed
    // Sirius, and never returns. A bundle with any other feed (every
    // release) ignores the flag.
    static func runLocalCheckIfRequested(bundle: Bundle = .main) {
        guard CommandLine.arguments.contains("--check-for-updates") else { return }
        let info = bundle.infoDictionary ?? [:]
        guard let feed = (info["SUFeedURL"] as? String).flatMap(URL.init(string:)),
              ["127.0.0.1", "localhost"].contains(feed.host ?? "") else {
            SiriusLog.app.info("--check-for-updates: ignored, the feed is not a local test feed")
            return
        }
        if let problem = configurationProblem(info: info) {
            SiriusLog.app.error("--check-for-updates: \(problem)")
            exit(1)
        }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: localCheck,
            userDriverDelegate: reminders
        )
        do {
            try controller.updater.start()
        } catch {
            SiriusLog.app.error("--check-for-updates: Sparkle didn't start: \(error.localizedDescription)")
            exit(1)
        }
        self.controller = controller
        SiriusLog.app.info("--check-for-updates: checking \(feed.absoluteString)")
        // A background check with automatic downloads (SUAutomaticallyUpdate
        // in the test build's Info.plist) shows no window; the delegate
        // installs at once instead of on quit.
        controller.updater.checkForUpdatesInBackground()
        NSApplication.shared.run()
        exit(0)
    }

    // Why this bundle can't update itself, or nil if it can. The build
    // number must be numeric (scripts/build-app.sh writes the commit
    // count), and a bundle without a real key would fail every check.
    nonisolated static func configurationProblem(info: [String: Any]) -> String? {
        let version = info["CFBundleVersion"] as? String ?? ""
        let isNumeric = !version.isEmpty
            && version.split(separator: ".", omittingEmptySubsequences: false)
                .allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
        guard isNumeric else { return "build number \(version.isEmpty ? "missing" : version) is not numeric" }

        guard let feed = info["SUFeedURL"] as? String, URL(string: feed)?.scheme != nil else {
            return "no SUFeedURL"
        }
        // An Ed25519 public key is 32 bytes, base64-encoded.
        guard let key = info["SUPublicEDKey"] as? String,
              let bytes = Data(base64Encoded: key), bytes.count == 32 else {
            return "SUPublicEDKey is not set to a real key"
        }
        return nil
    }
}

// Sirius has no Dock icon and is never frontmost, so a scheduled check that
// finds an update brings its window forward instead of leaving it behind
// the app in use. Declaring gentle-reminder support also stops Sparkle
// warning that a background app might miss the alert. Sparkle calls its
// delegates on the main thread only.
@MainActor
private final class UpdateReminders: NSObject, @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard handleShowingUpdate else { return }
        NSApp.activate(ignoringOtherApps: true)
    }
}

// The local test check's delegate: logs each step to sirius.log and
// installs a downloaded update at once. Exits when there is nothing to do.
@MainActor
private final class LocalCheck: NSObject, @preconcurrency SPUUpdaterDelegate {
    private let log = SiriusLog.app

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        log.info("--check-for-updates: found \(item.displayVersionString) (\(item.versionString)) at \(item.fileURL?.absoluteString ?? "?")")
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        log.info("--check-for-updates: no update: \(error.localizedDescription)")
        exit(0)
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        log.info("--check-for-updates: downloaded \(item.displayVersionString)")
    }

    func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) {
        log.info("--check-for-updates: extracted \(item.displayVersionString)")
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        log.info("--check-for-updates: installing \(item.displayVersionString)")
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        log.info("--check-for-updates: installing \(item.displayVersionString) now")
        immediateInstallHandler()
        return true
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        log.info("--check-for-updates: relaunching")
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        log.error("--check-for-updates: aborted: \(error.localizedDescription)")
        exit(1)
    }
}
