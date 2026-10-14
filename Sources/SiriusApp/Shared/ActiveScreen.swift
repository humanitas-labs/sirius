import AppKit

extension NSScreen {
    // The screen the user is working on (the toast kept opening on the main
    // monitor): NSScreen.main, the screen with the window
    // that has keyboard focus, else the one under the pointer. Not the window
    // list (CGWindowListCopyWindowInfo): reading other apps' windows asks for
    // Screen Recording on current macOS, even for their bounds.
    @MainActor
    static var active: NSScreen? {
        // SIRIUS_SCREEN=builtin puts every panel on the built-in display, to
        // profile it at 120 Hz without moving focus (dev).
        if ProcessInfo.processInfo.environment["SIRIUS_SCREEN"] == "builtin",
           let builtIn = screens.first(where: { screen in
               (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
                   .map { CGDisplayIsBuiltin($0) != 0 } ?? false
           }) {
            return builtIn
        }
        if let main { return main }
        let mouse = NSEvent.mouseLocation
        return screens.first { $0.frame.contains(mouse) }
    }
}
