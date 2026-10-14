import AppKit
import Carbon.HIToolbox
import SiriusCore

// A system-wide shortcut through Carbon's RegisterEventHotKey, which needs no
// Accessibility permission. Lives as long as the app. The handler is
// installed once; the key can be registered again (`register`), for the
// onboarding's rebinding, and set aside while a new one is recorded
// (`unregister`).
@MainActor
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    private static let id = EventHotKeyID(signature: OSType(0x5352_5553), id: 1) // "SRUS"

    // Nil when the handler could not be installed. The key itself may still
    // have failed to register: see `registered`.
    init?(action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData else { return noErr }
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            let delay = event.map { GetCurrentEventTime() - GetEventTime($0) } ?? 0
            MainActor.assumeIsolated {
                ComposerSignposts.hotKey(delay: delay)
                hotKey.action()
            }
            return noErr
        }, 1, &spec, me, &handler)
        guard installed == noErr else { return nil }
    }

    var registered: Bool { ref != nil }

    // Registers `combo` in place of the current key. noErr, or Carbon's
    // status: eventHotKeyExistsErr when another app holds it exclusively.
    // Carbon reports only that: a plain registration by another app is
    // accepted twice without a word (tested 2026.10.11). Sirius registers
    // exclusively, so an app that asks after it hears so. On failure no key
    // is registered.
    @discardableResult
    func register(_ combo: KeyCombo) -> OSStatus {
        unregister()
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, Self.id, GetApplicationEventTarget(),
                                         OptionBits(kEventHotKeyExclusive), &newRef)
        if status == noErr { ref = newRef }
        return status
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }

    // macOS's own shortcuts (Spotlight, screenshots, Mission Control...),
    // which RegisterEventHotKey does not report as taken.
    static func symbolicHotKeys() -> [SymbolicHotKey] {
        var array: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&array) == noErr,
              let entries = array?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard let code = (entry[kHISymbolicHotKeyCode] as? NSNumber)?.uint32Value,
                  let modifiers = (entry[kHISymbolicHotKeyModifiers] as? NSNumber)?.uint32Value else { return nil }
            let enabled = (entry[kHISymbolicHotKeyEnabled] as? NSNumber)?.boolValue ?? true
            return SymbolicHotKey(keyCode: code, modifiers: modifiers, enabled: enabled)
        }
    }
}

// A combo as glyphs, "⌘⇧J": the modifiers, then the key as the current
// keyboard layout prints it, or its name for the keys that print nothing.
enum KeyComboText {
    static func string(_ combo: KeyCombo) -> String {
        combo.modifierGlyphs + key(combo.keyCode)
    }

    private static let named: [UInt32: String] = [
        UInt32(kVK_Space): "Space", UInt32(kVK_Return): "↩", UInt32(kVK_Tab): "⇥", UInt32(kVK_Delete): "⌫",
        UInt32(kVK_ForwardDelete): "⌦", UInt32(kVK_Escape): "⎋", UInt32(kVK_LeftArrow): "←",
        UInt32(kVK_RightArrow): "→", UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_Home): "↖", UInt32(kVK_End): "↘", UInt32(kVK_PageUp): "⇞", UInt32(kVK_PageDown): "⇟",
    ]

    // The combo as a menu item's key equivalent, for the menu's Compose
    // hint: the key as the layout types it, lowercased, or an F-key's
    // function-key character; nil for a key a menu cannot show.
    static func menuKey(_ combo: KeyCombo) -> (key: String, modifiers: NSEvent.ModifierFlags)? {
        var modifiers: NSEvent.ModifierFlags = []
        if combo.modifiers & KeyCombo.command != 0 { modifiers.insert(.command) }
        if combo.modifiers & KeyCombo.shift != 0 { modifiers.insert(.shift) }
        if combo.modifiers & KeyCombo.option != 0 { modifiers.insert(.option) }
        if combo.modifiers & KeyCombo.control != 0 { modifiers.insert(.control) }
        if let name = KeyCombo.functionKeys[combo.keyCode], let number = Int(name.dropFirst()),
           let scalar = UnicodeScalar(NSF1FunctionKey + number - 1) {
            return (String(Character(scalar)), modifiers)
        }
        if let special = menuSpecial[combo.keyCode] { return (special, modifiers) }
        guard let typed = translated(combo.keyCode), typed.count == 1 else { return nil }
        return (typed.lowercased(), modifiers)
    }

    private static let menuSpecial: [UInt32: String] = [
        UInt32(kVK_Space): " ", UInt32(kVK_Return): "\r", UInt32(kVK_Tab): "\t",
        UInt32(kVK_Delete): String(Character(UnicodeScalar(NSBackspaceCharacter)!)),
        UInt32(kVK_Escape): "\u{1b}",
    ]

    static func key(_ code: UInt32) -> String {
        if let name = KeyCombo.functionKeys[code] ?? named[code] { return name }
        return translated(code)?.uppercased() ?? "#\(code)"
    }

    // UCKeyTranslate with the current layout, no modifiers.
    private static func translated(_ code: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> String? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var dead: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0,
                                        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                        &dead, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            let text = String(utf16CodeUnits: chars, count: length)
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        }
    }
}
