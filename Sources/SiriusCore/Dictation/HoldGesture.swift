import Foundation

// What a dictating hold does with its transcript: talk to an agent (the
// hold key alone), or paste at the cursor of the frontmost app (the hold
// key with its paste modifier, HoldKey.pasteModifier).
public enum DictationMode: Equatable, Sendable {
    case agent
    case paste
}

// The modifier flags a flagsChanged event carries, with CGEventFlags' raw
// bits, so the app passes `event.flags.rawValue` and this stays pure.
public struct HoldModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static let shift = HoldModifiers(rawValue: 0x0002_0000)   // maskShift
    public static let control = HoldModifiers(rawValue: 0x0004_0000) // maskControl
    public static let option = HoldModifiers(rawValue: 0x0008_0000)  // maskAlternate
    public static let command = HoldModifiers(rawValue: 0x0010_0000) // maskCommand
    public static let fn = HoldModifiers(rawValue: 0x0080_0000)      // maskSecondaryFn

    // Modifiers that make a press a chord; fn is not one of them.
    public static let chord: HoldModifiers = [.shift, .control, .option, .command]

    // Keeps only the bits above from a raw CGEventFlags value.
    public init(eventFlags: UInt64) {
        self.init(rawValue: eventFlags & (Self.chord.rawValue | Self.fn.rawValue))
    }

    // The flagsChanged keycodes of both sides of a modifier.
    var keycodes: Set<Int64> {
        var codes: Set<Int64> = []
        if contains(.shift) { codes.formUnion([56, 60]) }
        if contains(.control) { codes.formUnion([59, 62]) }
        if contains(.option) { codes.formUnion([58, 61]) }
        if contains(.command) { codes.formUnion([55, 54]) }
        if contains(.fn) { codes.insert(63) }
        return codes
    }
}

extension HoldKey {
    // The keycode its flagsChanged events carry (ParrotCore's HotkeyKey).
    var keycode: Int64 {
        switch self {
        case .fn: 63
        case .rightOption: 61
        case .rightCommand: 54
        case .control: 59
        }
    }

    // Its device-independent flag; left and right share it.
    public var flag: HoldModifiers {
        switch self {
        case .fn: .fn
        case .rightOption: .option
        case .rightCommand: .command
        case .control: .control
        }
    }
}

// Turns flagsChanged events into dictation edges for one hold key, as
// ParrotCore's HotkeyMonitor.input and Gesture do for the plain hold, with
// the paste chord added. Pure, so it is tested without a tap.
//
// - The key alone starts an agent hold, as before.
// - The key with its paste modifier already down starts a paste hold.
// - The paste modifier going down within `chordWindow` of the key turns
//   the hold into a paste hold, so the order of the two does not matter.
//   Recording started at the key, so nothing is lost.
// - Any other modifier, or the paste modifier past the window, cancels the
//   hold and the rest of it is ignored, as Gesture does: a shortcut typed
//   on the key gives no text.
// - Once pasting, the paste modifier may go up or down again freely; the
//   key's release ends the hold.
// - A hold shorter than `minimumHold` is discarded.
public struct HoldGesture {
    // Gesture.minimumHold: holds shorter than this are taps or shortcuts.
    public static let minimumHold: TimeInterval = 0.3
    // How long after the key the paste modifier may still join it.
    public static let chordWindow: TimeInterval = 0.3

    public enum Action: Equatable {
        // Start recording, for this mode.
        case start(DictationMode)
        // The hold started as an agent hold is now a paste hold.
        case paste
        // Stop recording and transcribe.
        case transcribe
        // Stop recording and discard it.
        case cancel
    }

    private enum Phase: Equatable {
        case idle
        case recording(since: TimeInterval, mode: DictationMode)
        // The key is down but this hold is a chord: ignored until release.
        case ignoring
    }

    // The flagsChanged keycodes of every modifier, both sides, and fn;
    // others (Caps Lock) are not a chord.
    static let modifierKeycodes: Set<Int64> = [54, 55, 56, 58, 59, 60, 61, 62, 63]

    public private(set) var key: HoldKey
    private var phase: Phase = .idle

    public init(key: HoldKey = .fn) {
        self.key = key
    }

    public var isHeld: Bool { phase != .idle }

    // One flagsChanged event at `time` (seconds on a monotonic clock).
    public mutating func handle(keycode: Int64, flags: HoldModifiers, at time: TimeInterval) -> Action? {
        let paste = key.pasteModifier
        let flagSet = flags.contains(key.flag)
        switch phase {
        case .idle:
            guard flagSet, key == .fn || keycode == key.keycode else { return nil }
            let others = flags.intersection(.chord).subtracting(key.flag)
            if others.isEmpty {
                phase = .recording(since: time, mode: .agent)
                return .start(.agent)
            }
            if others == paste {
                phase = .recording(since: time, mode: .paste)
                return .start(.paste)
            }
            phase = .ignoring
            return nil
        case .ignoring:
            if !flagSet || (key != .fn && keycode == key.keycode) { phase = .idle }
            return nil
        case .recording(let since, let mode):
            // The key went up: its flag is clear, or our side went up while
            // the other side still holds the shared flag.
            if !flagSet || (key != .fn && keycode == key.keycode) {
                phase = .idle
                return time - since < Self.minimumHold ? .cancel : .transcribe
            }
            guard keycode != key.keycode, Self.modifierKeycodes.contains(keycode) else { return nil }
            if paste.keycodes.contains(keycode) {
                if mode == .paste { return nil }
                let others = flags.intersection(.chord).subtracting(key.flag)
                if others == paste, time - since <= Self.chordWindow {
                    phase = .recording(since: since, mode: .paste)
                    return .paste
                }
            }
            phase = .ignoring
            return .cancel
        }
    }

    // The key went up unseen (a tap re-enabled after a missed release).
    public mutating func released(at time: TimeInterval) -> Action? {
        switch phase {
        case .idle: return nil
        case .ignoring:
            phase = .idle
            return nil
        case .recording(let since, _):
            phase = .idle
            return time - since < Self.minimumHold ? .cancel : .transcribe
        }
    }

    // Holds `newKey` from now on. A recording in progress is cancelled.
    public mutating func setKey(_ newKey: HoldKey) -> Action? {
        guard newKey != key else { return nil }
        key = newKey
        return reset()
    }

    // Forgets the current hold. A recording in progress is cancelled.
    public mutating func reset() -> Action? {
        defer { phase = .idle }
        if case .recording = phase { return .cancel }
        return nil
    }
}
