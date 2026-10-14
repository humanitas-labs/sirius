import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import ParrotCore
import SiriusCore

// The hold-to-talk tap: ParrotCore's HotkeyMonitor with the paste chord
// added (⌃fn pastes at the cursor; fn goes to the agent).
// HotkeyMonitor's Gesture cancels any chord, and both are pinned in
// Parrot's package, so Sirius holds this one tap in its place rather than
// a second beside it. The matching is SiriusCore's HoldGesture, tested; this
// file is the tap and its upkeep, as HotkeyMonitor's.
//
// flagsChanged only, listen-only, at the session tap, as HotkeyMonitor: no
// keystroke ever passes through it. macOS disables a tap that is slow or
// that user input disables; it is re-enabled at once, then with backoff
// (1 s doubling to 30 s) if that does not stick, and a watchdog checks it
// every 5 s in case a disable event is missed. Everything runs on the main
// thread.
@MainActor
final class HoldMonitor {
    enum Event: Equatable {
        // Start recording, for this mode.
        case pressed(DictationMode)
        // The hold is now a paste hold: the chord's modifier joined late.
        case paste
        case released
        case cancelled
    }

    enum TapError: Error { case tapCreateFailed }

    static let watchdogInterval: TimeInterval = 5
    private static let firstRetry: TimeInterval = 1
    private static let maxRetry: TimeInterval = 30
    private static let stableInterval: TimeInterval = 10

    private var gesture: HoldGesture
    private var onEvent: ((Event) -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var watchdog: Timer?
    private var retry: DispatchWorkItem?
    private var retryDelay: TimeInterval = 0
    private var enabledAt: Date?

    var onHealthChange: ((HotkeyHealth) -> Void)?
    private(set) var health: HotkeyHealth = .ok {
        didSet { if health != oldValue { onHealthChange?(health) } }
    }

    var key: HoldKey { gesture.key }

    init(key: HoldKey) {
        gesture = HoldGesture(key: key)
    }

    // Holds `key` from now on, without a new tap. A recording on the old
    // key is cancelled.
    func setKey(_ key: HoldKey) {
        if let action = gesture.setKey(key) { emit(action) }
    }

    func start(onEvent: @escaping (Event) -> Void) throws {
        self.onEvent = onEvent
        guard AXIsProcessTrusted() else { throw TapError.tapCreateFailed }
        let mask: CGEventMask = 1 << CGEventType.flagsChanged.rawValue
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: holdTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { throw TapError.tapCreateFailed }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        let watchdog = Timer(timeInterval: Self.watchdogInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkTap() }
        }
        RunLoop.main.add(watchdog, forMode: .common)
        self.watchdog = watchdog
    }

    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        retry?.cancel()
        retry = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        onEvent = nil
        _ = gesture.reset()
    }

    fileprivate func handle(keycode: Int64, flags: CGEventFlags) {
        let action = gesture.handle(keycode: keycode, flags: HoldModifiers(eventFlags: flags.rawValue),
                                    at: ProcessInfo.processInfo.systemUptime)
        if let action { emit(action) }
    }

    private func emit(_ action: HoldGesture.Action) {
        switch action {
        case .start(let mode): onEvent?(.pressed(mode))
        case .paste: onEvent?(.paste)
        case .transcribe: onEvent?(.released)
        case .cancel: onEvent?(.cancelled)
        }
    }

    // MARK: Recovery

    fileprivate func tapWasDisabled() {
        guard tap != nil, retry == nil else { return }
        // Undone within 10 s of the last re-enable: that one did not stick.
        if let enabledAt, Date().timeIntervalSince(enabledAt) < Self.stableInterval {
            retryDelay = retryDelay == 0 ? Self.firstRetry : min(retryDelay * 2, Self.maxRetry)
        } else {
            retryDelay = 0
        }
        enabledAt = nil
        if retryDelay == 0 {
            reenable()
        } else {
            scheduleRetry()
        }
    }

    private func reenable() {
        retry = nil
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        guard CGEvent.tapIsEnabled(tap: tap) else {
            retryDelay = retryDelay == 0 ? Self.firstRetry : min(retryDelay * 2, Self.maxRetry)
            scheduleRetry()
            return
        }
        SiriusLog.dictation.info("dictation: hold tap re-enabled")
        enabledAt = Date()
        health = .ok
        // The key may have gone up while the tap was off: end that hold.
        // A press missed meanwhile is not started halfway through.
        let flags = HoldModifiers(eventFlags: CGEventSource.flagsState(.combinedSessionState).rawValue)
        if gesture.isHeld, !flags.contains(gesture.key.flag), let action = gesture.released(at: ProcessInfo.processInfo.systemUptime) {
            emit(action)
        }
    }

    private func scheduleRetry() {
        let secureInput = IsSecureEventInputEnabled()
        health = .degraded(secureInput: secureInput)
        if retryDelay == 0 { retryDelay = Self.firstRetry }
        SiriusLog.dictation.error("dictation: hold tap disabled\(secureInput ? ", secure input active" : ""); retrying in \(Int(retryDelay))s")
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.reenable() }
        }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay, execute: work)
    }

    private func checkTap() {
        guard let tap, retry == nil, !CGEvent.tapIsEnabled(tap: tap) else { return }
        tapWasDisabled()
    }
}

private func holdTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HoldMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    // Return at once and work on the next main run loop turn: a slow
    // callback is what gets a tap disabled by timeout.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        DispatchQueue.main.async { MainActor.assumeIsolated { monitor.tapWasDisabled() } }
        return Unmanaged.passUnretained(event)
    }
    guard type == .flagsChanged else { return Unmanaged.passUnretained(event) }
    let keycode = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags
    DispatchQueue.main.async { MainActor.assumeIsolated { monitor.handle(keycode: keycode, flags: flags) } }
    return Unmanaged.passUnretained(event)
}
