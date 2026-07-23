import AppKit
import Foundation

struct KeyEventSnapshot: Sendable {
    let key: String
    let keyCode: UInt16
    let modifiersRawValue: UInt
    let isRepeat: Bool

    var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiersRawValue)
    }
}

struct KeyCombo: Equatable {
    let key: String?
    let keyCode: UInt16?
    let modifiers: NSEvent.ModifierFlags

    func matches(_ event: KeyEventSnapshot) -> Bool {
        let modifiersMatch = normalized(event.modifiers) == normalized(modifiers)
        guard modifiersMatch else {
            return false
        }

        if let keyCode {
            return event.keyCode == keyCode
        }

        if let key {
            return !event.key.isEmpty && event.key == key
        }

        return false
    }

    private func normalized(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        return flags.intersection([.command, .shift, .option, .control])
    }
}

struct HintTarget {
    let id = UUID()
    let axElement: AXUIElement
    let point: CGPoint
    let title: String
    let role: String
    let label: String
    var elementFrame: CGRect? = nil
}

extension HintTarget: @unchecked Sendable {}

enum HackeyMode {
    case idle
    case click
    case scroll
}

struct AppConfig {
    // Deliberately NOT keyCode 49 (backtick): Shift+backtick alone types the "~"
    // character, so using it (or any bare-modifier variant of it) as a global
    // activation shortcut meant Hackey silently hijacked click mode every time a
    // user typed a literal "~" anywhere (Terminal paths, markdown, URLs, etc.) -
    // and mid-sentence keystrokes right after got consumed as bogus hint labels,
    // which looked exactly like "clicking does something completely different."
    // Backtick is ALSO the toggle key for the third-party "Shortcat" app
    // (Option+backtick, see ~/Library/Preferences/com.sproutcube.Shortcat.plist)
    // - sharing a base key across two active global-hotkey listeners makes it
    // very easy to fat-finger the wrong modifier and launch the wrong app's
    // overlay entirely. Both defaults now require two modifiers on a key with no
    // common unmodified-typing meaning, and don't collide with Shortcat's bindings.
    var clickActivationPrimary = KeyCombo(key: nil, keyCode: 40, modifiers: [.command, .shift])
    var clickActivationSecondary = KeyCombo(key: nil, keyCode: 40, modifiers: [.command, .option])
    var scrollActivation = KeyCombo(key: nil, keyCode: 38, modifiers: [.command, .shift])
    var labelsOnlyMode = false
    var maxTargets = 160
    // Bundle IDs the user never wants Hackey to activate over (e.g. a game, a
    // remote-desktop client, or any app whose own shortcuts should never be
    // intercepted). Persisted via SettingsStore; edited via the menu bar's
    // "Ignore Current App" toggle or by hand in the settings JSON file.
    var ignoredBundleIDs: Set<String> = []
}
