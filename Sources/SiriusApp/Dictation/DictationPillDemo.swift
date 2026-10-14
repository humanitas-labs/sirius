import AppKit

// The pill's previews, from the menu-bar menu's Debug items (Option-click),
// for seeing each state live before the dictation loop drives it: the
// mark, about 2 s of recording on a fake level, 1 s transcribing, then the
// close; and the download counting 0 to 100%. Times stretch with the Debug
// slow motion.
@MainActor
enum DictationPillDemo {
    // TODO(copy): the Sirius mark. The status item's sparkle for now.
    static let pill = DictationPill(mark: NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Sirius"))
    private static var timer: Timer?

    static func dictation() {
        stop()
        let scale = SpatialMotion.timeScale
        let recordUntil = DictationPill.markHold + 2 * scale
        let start = ProcessInfo.processInfo.systemUptime
        pill.dictationStarted()
        // A level about every 12 ms, as capture delivers it: a slow swell
        // with a faster flutter, from near silence to about speech's peaks.
        timer = Timer.scheduledTimer(withTimeInterval: 0.012, repeats: true) { _ in
            MainActor.assumeIsolated {
                let t = (ProcessInfo.processInfo.systemUptime - start) / scale
                guard t * scale < recordUntil else {
                    stop()
                    pill.dictationTranscribing()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1 * scale) {
                        MainActor.assumeIsolated { pill.dictationFinished() }
                    }
                    return
                }
                let swell = 0.5 + 0.5 * sin(2 * .pi * 0.9 * t)
                let flutter = 0.5 + 0.5 * sin(2 * .pi * 5.3 * t)
                pill.level(Float(0.004 + 0.06 * swell * (0.6 + 0.4 * flutter)))
            }
        }
    }

    static func download() {
        stop()
        let scale = SpatialMotion.timeScale
        let duration = 3 * scale
        let start = ProcessInfo.processInfo.systemUptime
        pill.progress(0, label: "Downloading speech model")
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                let fraction = (ProcessInfo.processInfo.systemUptime - start) / duration
                guard fraction < 1 else {
                    stop()
                    pill.progress(1, label: "Downloading speech model")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4 * scale) {
                        MainActor.assumeIsolated { pill.progress(nil, label: "") }
                    }
                    return
                }
                pill.progress(fraction, label: "Downloading speech model")
            }
        }
    }

    private static func stop() {
        timer?.invalidate()
        timer = nil
    }
}
