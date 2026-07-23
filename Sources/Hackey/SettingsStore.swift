import AppKit
import Foundation

/// A Codable, on-disk representation of `KeyCombo` (which itself holds a raw
/// `NSEvent.ModifierFlags` that isn't directly Codable). Modifiers are stored as
/// plain strings so the JSON file stays hand-editable.
struct PersistedKeyCombo: Codable, Equatable {
    var key: String?
    var keyCode: UInt16?
    var modifiers: [String]

    static func from(_ combo: KeyCombo) -> PersistedKeyCombo {
        var mods: [String] = []
        if combo.modifiers.contains(.command) { mods.append("command") }
        if combo.modifiers.contains(.shift) { mods.append("shift") }
        if combo.modifiers.contains(.option) { mods.append("option") }
        if combo.modifiers.contains(.control) { mods.append("control") }
        return PersistedKeyCombo(key: combo.key, keyCode: combo.keyCode, modifiers: mods)
    }

    func toKeyCombo() -> KeyCombo {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains("command") { flags.insert(.command) }
        if modifiers.contains("shift") { flags.insert(.shift) }
        if modifiers.contains("option") { flags.insert(.option) }
        if modifiers.contains("control") { flags.insert(.control) }
        return KeyCombo(key: key, keyCode: keyCode, modifiers: flags)
    }
}

/// Everything a user can customize, persisted as JSON so it survives relaunches.
/// This covers the plan-phase "shortcut customization", "per-app ignore list",
/// and "local settings persistence" features - editable by hand (Reveal Settings
/// File) since there's no separate keybinding-editor GUI window, per the local
/// personal-use-only scope agreed at plan time.
struct PersistedSettings: Codable {
    var clickActivationPrimary: PersistedKeyCombo
    var clickActivationSecondary: PersistedKeyCombo
    var scrollActivation: PersistedKeyCombo
    var labelsOnlyMode: Bool
    var scrollSpeed: Int32
    var maxTargets: Int
    var ignoredBundleIDs: [String]

    static func defaults() -> PersistedSettings {
        let base = AppConfig()
        return PersistedSettings(
            clickActivationPrimary: .from(base.clickActivationPrimary),
            clickActivationSecondary: .from(base.clickActivationSecondary),
            scrollActivation: .from(base.scrollActivation),
            labelsOnlyMode: base.labelsOnlyMode,
            scrollSpeed: 42,
            maxTargets: base.maxTargets,
            ignoredBundleIDs: []
        )
    }
}

@MainActor
final class SettingsStore {
    private let fileURL: URL

    init() {
        let supportDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Hackey", isDirectory: true)
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        fileURL = supportDir.appendingPathComponent("settings.json")
    }

    var path: String { fileURL.path }

    /// Loads settings from disk, writing out a fresh defaults file the first time
    /// (so the user has something to find/edit via "Reveal Settings File").
    func load() -> PersistedSettings {
        guard let data = try? Data(contentsOf: fileURL),
              let settings = try? JSONDecoder().decode(PersistedSettings.self, from: data) else {
            let defaults = PersistedSettings.defaults()
            save(defaults)
            return defaults
        }
        return settings
    }

    func save(_ settings: PersistedSettings) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(settings) else {
            return
        }
        try? data.write(to: fileURL, options: .atomic)
    }
}
