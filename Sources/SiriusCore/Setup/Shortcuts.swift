import Foundation

// The two shortcuts the onboarding's last page shows, and their rules
// (the design and the spec's "Rebindable shortcuts"). Compose is a
// Carbon hot key (the app's HotKey), freely recorded; hold to talk is a
// modifier held under the Accessibility event tap (ParrotCore's
// HotkeyMonitor), so it can only be one of a short list. Both persist in
// UserDefaults.

// A recorded key and its modifiers, as Carbon's RegisterEventHotKey and
// CopySymbolicHotKeys take them: a kVK_ virtual key code and Carbon's
// modifier bits (cmdKey, shiftKey, optionKey, controlKey).
public struct KeyCombo: Codable, Equatable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.modifierMask
    }

    // Carbon's modifier bits (Events.h).
    public static let command: UInt32 = 1 << 8
    public static let shift: UInt32 = 1 << 9
    public static let option: UInt32 = 1 << 11
    public static let control: UInt32 = 1 << 12
    // The bits a hot key compares on; CopySymbolicHotKeys also sets others,
    // such as fn (1 << 17) on the F-keys.
    public static let modifierMask: UInt32 = command | shift | option | control

    // ⌘⇧J, the default (kVK_ANSI_J).
    public static let compose = KeyCombo(keyCode: 38, modifiers: command | shift)

    // F1 to F20's kVK_ codes.
    public static let functionKeys: [UInt32: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]

    public var isFunctionKey: Bool { Self.functionKeys[keyCode] != nil }

    // A shortcut needs ⌘, ⌃ or ⌥, so it never takes a key the user types;
    // an F-key may stand alone or with ⇧ (the spec).
    public var isAcceptable: Bool {
        isFunctionKey || modifiers & (Self.command | Self.control | Self.option) != 0
    }

    // The modifiers as the frames write them: ⌘⇧J (115:319), so ⌘ before
    // ⇧, where macOS's menus put ⇧ first (⌃⌥⇧⌘).
    public var modifierGlyphs: String {
        var glyphs = ""
        if modifiers & Self.control != 0 { glyphs += "⌃" }
        if modifiers & Self.option != 0 { glyphs += "⌥" }
        if modifiers & Self.command != 0 { glyphs += "⌘" }
        if modifiers & Self.shift != 0 { glyphs += "⇧" }
        return glyphs
    }

    // Whether macOS's own shortcut `entry` (CopySymbolicHotKeys) is this
    // one: an enabled entry with the same key and modifiers.
    public func clashes(withSymbolic entry: SymbolicHotKey) -> Bool {
        entry.enabled && entry.keyCode == keyCode && entry.modifiers & Self.modifierMask == modifiers
    }
}

// One of macOS's own shortcuts, as CopySymbolicHotKeys lists it.
public struct SymbolicHotKey: Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    public var enabled: Bool

    public init(keyCode: UInt32, modifiers: UInt32, enabled: Bool) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.enabled = enabled
    }
}

// The keys hold to talk can be: the ones a hand can hold without typing
// (the spec). The raw values are ParrotCore's HotkeyKey names. ⌃ is the
// left Control key, the one every keyboard has.
public enum HoldKey: String, CaseIterable, Codable, Sendable {
    case fn
    case rightOption = "right-option"
    case rightCommand = "right-command"
    case control = "left-control"

    // As the row and the subtitle show it.
    public var glyph: String {
        switch self {
        case .fn: "fn"
        case .rightOption: "right ⌥"
        case .rightCommand: "right ⌘"
        case .control: "⌃"
        }
    }

    // As the list offers it.
    public var menuTitle: String {
        switch self {
        case .fn: "fn (Globe)"
        case .rightOption: "Right Option (⌥)"
        case .rightCommand: "Right Command (⌘)"
        case .control: "Control (⌃)"
        }
    }

    // The modifier that, held with this key, pastes at the cursor rather
    // than talking to an agent: ⌃, or ⇧ when the hold key is ⌃ itself
    // (⌃fn pastes at the cursor; fn goes to the agent).
    public var pasteModifier: HoldModifiers {
        self == .control ? .shift : .control
    }

    // The paste chord as a row or a log line shows it: ⌃fn, ⌃ right ⌥,
    // ⌃ right ⌘, ⌃⇧.
    public var pasteGlyph: String {
        switch self {
        case .fn: "⌃fn"
        case .rightOption, .rightCommand: "⌃ \(glyph)"
        case .control: "⌃⇧"
        }
    }
}

public enum Shortcuts {
    public static let composeKey = "shortcut.compose"
    public static let holdKey = "shortcut.holdToTalk"

    public static func compose(in defaults: UserDefaults) -> KeyCombo {
        guard let data = defaults.data(forKey: composeKey),
              let combo = try? JSONDecoder().decode(KeyCombo.self, from: data),
              combo.isAcceptable else { return .compose }
        return combo
    }

    public static func setCompose(_ combo: KeyCombo, in defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(combo) else { return }
        defaults.set(data, forKey: composeKey)
    }

    // The sticky toast when the compose shortcut could not be registered,
    // in the user's own glyphs ("⌘⇧J").
    public static func takenMessage(_ glyphs: String) -> String {
        "\(glyphs) is taken by another app. Pick a new compose shortcut in Settings." // TODO(andrew): copy
    }

    public static func holdKey(in defaults: UserDefaults) -> HoldKey {
        defaults.string(forKey: holdKey).flatMap(HoldKey.init(rawValue:)) ?? .fn
    }

    public static func setHoldKey(_ key: HoldKey, in defaults: UserDefaults) {
        defaults.set(key.rawValue, forKey: holdKey)
    }
}
