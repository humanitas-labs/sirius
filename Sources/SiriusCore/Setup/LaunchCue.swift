import Foundation

// The launch cue's timing, with no AppKit: the app's LaunchCuePresenter
// shows the dictation pill holding the sparkle, its border's ring playing
// once, then growing to say "Listening.", from launch until Sirius is
// ready. Ready is the
// socket server up, which it is before the cue shows, the registered agents
// started warm, and the speech model loaded when it was already on disk at
// launch; a first-time download is not waited for, as it has its own
// "Preparing speech…" in the pill. The pill stays long enough never to
// flicker and leaves on time even when something is slow.
// TODO(copy): the launch cue is a first pass.
public enum LaunchCue {
    // The least time the pill shows, so a fast launch does not flicker it
    // and "Listening.", in from 1.25 s, holds long enough to read: 3.7 s
    // (2.2, then a second longer, then the sparkle alone half a second
    // longer before the grow).
    public static let minimum: TimeInterval = 3.7
    // The most, so a slow agent or model never leaves it lingering.
    public static let maximum: TimeInterval = 6

    // When "Listening." starts to come in, from the cue's start: the
    // pill's grow at 1.1 s and the word half-way into its 0.3 s resize
    // (DictationPill.growDelay, wordDelay), at the normal motion speed.
    public static let wordAppears: TimeInterval = 1.25

    // The launch sound: Hero's two soft pickups as a
    // fill, at about 0.06 s and 0.12 s into it, landing on Glass. Hero
    // plays only up to its cut, fading out over the last few milliseconds,
    // so its own hit at 0.18 s is never heard; Glass starts 0.18 s after
    // Hero, where that hit was, and rings out in full. Both are macOS's own
    // sounds, read from /System/Library/Sounds at launch, never bundled.
    public enum Sound {
        // When the sound starts, from the cue's start, so that Glass lands
        // with the word: start + glassOffset = wordAppears.
        public static let start: TimeInterval = wordAppears - glassOffset
        // Where Hero is cut, just short of its own hit.
        public static let heroCut: TimeInterval = 0.175
        // The fade-out ending at the cut.
        public static let heroFade: TimeInterval = 0.012
        // Hero's level: its own.
        public static let heroGain: Float = 1
        // When Glass starts, from Hero's start.
        public static let glassOffset: TimeInterval = 0.18
        // Glass's level, a little under its own.
        public static let glassGain: Float = 0.9
        // The mix's level at the output, as auditioned at `afplay -v 0.5`.
        public static let volume: Float = 0.5
    }

    // Whether the pill leaves now, `elapsed` seconds after it showed.
    public static func leaves(elapsed: TimeInterval, ready: Bool) -> Bool {
        elapsed >= maximum || (ready && elapsed >= minimum)
    }
}
