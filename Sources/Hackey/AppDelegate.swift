import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let coordinator = HackeyCoordinator()
    private let instanceGuard = SingleInstanceGuard()
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard instanceGuard.acquire() else {
            NSApp.terminate(nil)
            return
        }

        coordinator.start()
        installMenuBarItem()
    }

    private func installMenuBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.title = "Hackey"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Activate Click Mode", action: #selector(activateClickMode), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Activate Scroll Mode", action: #selector(activateScrollMode), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Show Diagnostics", action: #selector(showDiagnostics), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Run System Coverage Audit", action: #selector(runSystemCoverageAudit), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Toggle Labels-only Mode", action: #selector(toggleLabelsOnly), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Ignore/Un-ignore Current App", action: #selector(toggleIgnoreCurrentApp), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Reload Settings", action: #selector(reloadSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Reveal Settings File in Finder", action: #selector(revealSettingsFile), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Hackey", action: #selector(quit), keyEquivalent: "q"))

        menu.items.forEach { $0.target = self }
        statusItem?.menu = menu
    }

    @objc
    private func toggleLabelsOnly() {
        coordinator.toggleLabelsOnly()
    }

    @objc
    private func toggleIgnoreCurrentApp() {
        guard let (appName, isIgnored) = coordinator.toggleIgnoreForFrontmostApp() else {
            return
        }
        let alert = NSAlert()
        alert.messageText = isIgnored ? "App Ignored" : "App Un-ignored"
        alert.informativeText = isIgnored
            ? "Hackey will no longer activate over \(appName)."
            : "Hackey will activate over \(appName) again."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc
    private func reloadSettings() {
        coordinator.reloadSettingsFromDisk()
    }

    @objc
    private func revealSettingsFile() {
        NSWorkspace.shared.selectFile(coordinator.settingsFilePath, inFileViewerRootedAtPath: "")
    }

    @objc
    private func activateClickMode() {
        coordinator.activateClickModeFromMenu()
    }

    @objc
    private func activateScrollMode() {
        coordinator.activateScrollModeFromMenu()
    }

    @objc
    private func showDiagnostics() {
        let alert = NSAlert()
        alert.messageText = "Hackey Diagnostics"
        alert.informativeText = coordinator.diagnosticsSummary()
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc
    private func runSystemCoverageAudit() {
        let alert = NSAlert()
        alert.messageText = "Hackey Coverage Audit"

        if let url = coordinator.runSystemCoverageAudit() {
            alert.informativeText = "Audit complete.\nSaved to:\n\(url.path)"
        } else {
            alert.informativeText = "Audit failed to write report file."
        }

        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc
    private func quit() {
        NSApp.terminate(nil)
    }
}
