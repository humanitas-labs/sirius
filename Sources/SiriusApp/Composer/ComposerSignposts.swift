import os

// The summon's timeline, for the cold-start lag: an interval
// from the hotkey to the first key the text view takes, with events at the
// steps between. Read with
// `log stream --signpost --predicate 'subsystem == "com.humanitas.sirius"'`
// or Instruments' os_signpost track.
@MainActor
enum ComposerSignposts {
    static let signposter = OSSignposter(subsystem: "com.humanitas.sirius", category: "composer")
    private static var summon: OSSignpostIntervalState?

    // The hotkey arrived; `delay` is how long the event waited before the
    // app handled it, which App Nap or timer coalescing would stretch.
    static func hotKey(delay: Double) {
        if let summon { signposter.endInterval("summon", summon, "superseded") }
        summon = signposter.beginInterval("summon", id: signposter.makeSignpostID(),
                                          "delay \(Int(delay * 1000)) ms")
    }

    static func event(_ name: StaticString) {
        signposter.emitEvent(name)
    }

    // The first key after a summon, the end of its interval.
    static func firstKey() {
        guard let state = summon else { return }
        summon = nil
        signposter.endInterval("summon", state)
    }
}
