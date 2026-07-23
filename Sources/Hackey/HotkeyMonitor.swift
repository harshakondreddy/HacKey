import AppKit
import Foundation

/// Captures global key events via a CGEventTap so Hackey can actually CONSUME
/// (block) keystrokes while its click/scroll mode is active - not just observe
/// them. `NSEvent.addGlobalMonitorForEvents` (the previous implementation) is
/// documented as passive/listen-only and can never swallow an event: every
/// label keystroke typed while Hackey's overlay was showing was ALSO delivered
/// to the real frontmost app completely normally. On pages with their own
/// single-key/shift+letter keyboard shortcuts (Confluence, Jira, Gmail, many
/// web apps), that meant typing a hint label like "SE" simultaneously fired
/// whatever shortcut the underlying page bound to those same letters - the
/// exact "it triggered the app's own shortcut instead of the actual click"
/// symptom. A CGEventTap created with `.defaultTap` (not `.listenOnly`) lets
/// the callback return `nil` to genuinely block an event from propagating
/// further once Hackey decides it owns that keystroke.
final class HotkeyMonitor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Returns `true` if Hackey has fully handled the event and it must NOT be
    /// delivered to any other app; `false` to let it pass through untouched.
    private let handler: @MainActor (KeyEventSnapshot) -> Bool

    init(handler: @escaping @MainActor (KeyEventSnapshot) -> Bool) {
        self.handler = handler
    }

    func start() {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, cgEvent, refcon in
                guard let refcon else {
                    return Unmanaged.passUnretained(cgEvent)
                }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handleTapEvent(type: type, cgEvent: cgEvent)
            },
            userInfo: refcon
        ) else {
            // Falls back to a passive monitor (best-effort, can't consume events)
            // if the tap couldn't be created (e.g. Accessibility permission not
            // yet granted) - keeps the app at least partially usable while the
            // user grants permission, rather than doing nothing at all.
            fallbackMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.emitFallback(event)
            }
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private var fallbackMonitor: Any?

    private func handleTapEvent(type: CGEventType, cgEvent: CGEvent) -> Unmanaged<CGEvent>? {
        // The OS disables a tap if it's too slow to respond or the user does
        // something like invoke Secure Input - must be explicitly re-enabled or
        // Hackey silently stops receiving ANY key events until relaunch.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(cgEvent)
        }

        guard type == .keyDown,
              let nsEvent = NSEvent(cgEvent: cgEvent),
              let key = nsEvent.charactersIgnoringModifiers?.lowercased(),
              !key.isEmpty else {
            return Unmanaged.passUnretained(cgEvent)
        }

        let modifiers = nsEvent.modifierFlags.intersection([.command, .shift, .option, .control])
        let snapshot = KeyEventSnapshot(
            key: key,
            keyCode: nsEvent.keyCode,
            modifiersRawValue: modifiers.rawValue,
            isRepeat: nsEvent.isARepeat
        )

        // The tap's run loop source is attached to the main run loop, so this
        // callback always runs on the main thread - safe to synchronously enter
        // MainActor-isolated code here without hopping through Task {}, which
        // would make the block/pass-through decision arrive too late to matter.
        // Capture the handler function value into a local first (rather than
        // referencing `self.handler` inside the closure below) so the closure
        // doesn't implicitly capture non-Sendable `self` across the isolation hop.
        let handlerFn = handler
        let consumed = MainActor.assumeIsolated {
            handlerFn(snapshot)
        }

        return consumed ? nil : Unmanaged.passUnretained(cgEvent)
    }

    private func emitFallback(_ event: NSEvent) {
        guard let key = event.charactersIgnoringModifiers?.lowercased(), !key.isEmpty else {
            return
        }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let snapshot = KeyEventSnapshot(
            key: key,
            keyCode: event.keyCode,
            modifiersRawValue: modifiers.rawValue,
            isRepeat: event.isARepeat
        )
        let handlerFn = handler
        MainActor.assumeIsolated {
            _ = handlerFn(snapshot)
        }
    }

    deinit {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let fallbackMonitor {
            NSEvent.removeMonitor(fallbackMonitor)
        }
    }
}

