import AppKit
import Dispatch
import Foundation

@MainActor
final class HackeyCoordinator {
    private let permissions = AccessibilityPermissionManager()
    private let scanner = AXElementScanner()
    private let overlay = OverlayManager()
    private let performer = InteractionPerformer()
    private let settingsStore = SettingsStore()

    private var config = AppConfig()
    private var mode: HackeyMode = .idle
    private var visibleTargets: [HintTarget] = []
    private var cachedClickTargets: [HintTarget] = []
    private var frontAppClickTargets: [HintTarget] = []
    private var clickClipFrame: CGRect?
    private var clickModeActivatedAt = Date.distantPast
    private var activeClickAppPID: pid_t?
    private var focusedIndex = 0
    private var query = ""
    private var labelBuffer = ""
    private var scrollSpeed: Int32 = 42
    private var lastEventFingerprint: String = ""
    private var lastEventAt: TimeInterval = 0

    lazy var hotkeys = HotkeyMonitor { [weak self] event in
        self?.handle(event) ?? false
    }

    func start() {
        applyPersistedSettings(settingsStore.load())
        permissions.ensurePermission()
        hotkeys.start()
    }

    func toggleLabelsOnly() {
        config.labelsOnlyMode.toggle()
        persistCurrentSettings()
    }

    /// Re-reads settings.json from disk and applies it immediately, so a user can
    /// hand-edit shortcuts/ignore list/scroll speed and pick them up without
    /// relaunching the app.
    func reloadSettingsFromDisk() {
        applyPersistedSettings(settingsStore.load())
    }

    var settingsFilePath: String {
        settingsStore.path
    }

    /// Adds/removes the current frontmost app's bundle ID from the ignore list and
    /// persists the change immediately. Returns the new ignored state so the menu
    /// can show feedback (e.g. via an alert) without needing a second query.
    func toggleIgnoreForFrontmostApp() -> (appName: String, isIgnored: Bool)? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else {
            return nil
        }

        if config.ignoredBundleIDs.contains(bundleID) {
            config.ignoredBundleIDs.remove(bundleID)
        } else {
            config.ignoredBundleIDs.insert(bundleID)
        }
        persistCurrentSettings()
        return (app.localizedName ?? bundleID, config.ignoredBundleIDs.contains(bundleID))
    }

    private func applyPersistedSettings(_ settings: PersistedSettings) {
        config.clickActivationPrimary = settings.clickActivationPrimary.toKeyCombo()
        config.clickActivationSecondary = settings.clickActivationSecondary.toKeyCombo()
        config.scrollActivation = settings.scrollActivation.toKeyCombo()
        config.labelsOnlyMode = settings.labelsOnlyMode
        config.maxTargets = settings.maxTargets
        config.ignoredBundleIDs = Set(settings.ignoredBundleIDs)
        scrollSpeed = settings.scrollSpeed
    }

    private func persistCurrentSettings() {
        let settings = PersistedSettings(
            clickActivationPrimary: .from(config.clickActivationPrimary),
            clickActivationSecondary: .from(config.clickActivationSecondary),
            scrollActivation: .from(config.scrollActivation),
            labelsOnlyMode: config.labelsOnlyMode,
            scrollSpeed: scrollSpeed,
            maxTargets: config.maxTargets,
            ignoredBundleIDs: Array(config.ignoredBundleIDs).sorted()
        )
        settingsStore.save(settings)
    }

    /// True if the frontmost app is on the user's ignore list - Hackey must never
    /// activate click/scroll mode over it (e.g. games, remote-desktop clients).
    private func isFrontmostAppIgnored() -> Bool {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return false
        }
        return config.ignoredBundleIDs.contains(bundleID)
    }

    func activateClickModeFromMenu() {
        toggleClickMode()
    }

    func activateScrollModeFromMenu() {
        toggleScrollMode()
    }

    func runSelfTestOverlay() {
        guard let screen = NSScreen.main else {
            return
        }

        let frame = screen.visibleFrame
        let rows = 6
        let columns = 10
        var targets: [HintTarget] = []
        let labels = AXElementScanner.makeLabels(count: rows * columns)
        let systemWide = AXUIElementCreateSystemWide()

        var index = 0
        for row in 0..<rows {
            for col in 0..<columns {
                let x = frame.minX + CGFloat(col + 1) * (frame.width / CGFloat(columns + 1))
                let y = frame.minY + CGFloat(row + 1) * (frame.height / CGFloat(rows + 1))
                let target = HintTarget(
                    axElement: systemWide,
                    point: CGPoint(x: x, y: y),
                    title: "self-test",
                    role: "AXButton",
                    label: labels[index]
                )
                targets.append(target)
                index += 1
            }
        }

        mode = .click
        query = "self-test"
        labelBuffer = ""
        visibleTargets = targets
        focusedIndex = 0
        render()
    }

    func diagnosticsSummary() -> String {
        let summary = scanner.diagnosticsSummary(maxCount: config.maxTargets)
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"
        return "Front app: \(appName)\n\(summary)"
    }

    func runSystemCoverageAudit() -> URL? {
        let runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .filter { $0.processIdentifier > 0 }
            .sorted { lhs, rhs in
                (lhs.localizedName ?? "") < (rhs.localizedName ?? "")
            }

        var lines: [String] = []
        lines.append("Hackey Coverage Audit")
        lines.append("Generated: \(Date())")
        lines.append("Apps audited: \(runningApps.count)")
        lines.append("")

        for app in runningApps {
            let name = app.localizedName ?? "Unknown"
            let bundleID = app.bundleIdentifier ?? "unknown.bundle"
            let details = scanner.diagnosticsSummary(for: app, maxCount: config.maxTargets)
            lines.append("=== \(name) (\(bundleID)) ===")
            lines.append(details)
            lines.append("")
        }

        let report = lines.joined(separator: "\n")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hackey-coverage-audit-\(stamp).txt")

        do {
            try report.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    /// Returns whether Hackey has fully handled `event` and it must be BLOCKED
    /// from reaching any other app. Every keystroke while click/scroll mode is
    /// active belongs to Hackey alone - letting it also leak through to the
    /// real frontmost app (e.g. a web page with its own single-letter keyboard
    /// shortcuts) is exactly what caused hint-label keystrokes to also trigger
    /// unrelated in-page shortcuts instead of just performing the intended click.
    private func handle(_ event: KeyEventSnapshot) -> Bool {
        let isActivationCombo = config.clickActivationPrimary.matches(event)
            || config.clickActivationSecondary.matches(event)
            || config.scrollActivation.matches(event)

        if shouldDropDuplicate(event) {
            return isActivationCombo || mode != .idle
        }

        if event.isRepeat && isActivationCombo {
            return true
        }

        if config.clickActivationPrimary.matches(event) || config.clickActivationSecondary.matches(event) {
            return toggleClickMode()
        }

        if config.scrollActivation.matches(event) {
            return toggleScrollMode()
        }

        switch mode {
        case .idle:
            return false
        case .click:
            handleClickMode(event)
            return true
        case .scroll:
            handleScrollMode(event)
            return true
        }
    }

    @discardableResult
    private func toggleClickMode() -> Bool {
        if mode == .click {
            deactivate()
            return true
        }

        guard permissions.isTrusted else {
            permissions.ensurePermission()
            return false
        }

        guard !isFrontmostAppIgnored() else {
            return false
        }

        mode = .click
        clickModeActivatedAt = Date()
        query = ""
        labelBuffer = ""
        activeClickAppPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        refreshClickTargets(rescan: true)
        return true
    }

    @discardableResult
    private func toggleScrollMode() -> Bool {
        if mode == .scroll {
            deactivate()
            return true
        }

        guard permissions.isTrusted else {
            permissions.ensurePermission()
            return false
        }

        guard !isFrontmostAppIgnored() else {
            return false
        }

        mode = .scroll
        query = ""
        labelBuffer = ""
        visibleTargets = scanner.scanScrollAreas()
        focusedIndex = min(focusedIndex, max(visibleTargets.count - 1, 0))
        render()
        return true
    }

    private func deactivate() {
        mode = .idle
        visibleTargets = []
        cachedClickTargets = []
        frontAppClickTargets = []
        clickClipFrame = nil
        activeClickAppPID = nil
        query = ""
        labelBuffer = ""
        overlay.hide()
    }

    private func refreshClickTargets(rescan: Bool = false) {
        if rescan || cachedClickTargets.isEmpty {
            var scan = timedScan()
            if scan.targets.isEmpty {
                // The frontmost app/window can occasionally still be settling right after
                // an app switch (AX attributes transiently return nothing). One short,
                // synchronous retry avoids surfacing a blank overlay for that transient case.
                Thread.sleep(forTimeInterval: 0.07)
                scan = timedScan()
            }
            cachedClickTargets = scan.targets
            frontAppClickTargets = cachedClickTargets
            clickClipFrame = scan.focusedFrame
        }

        let allTargets = clipTargetsToFocusedFrameIfAvailable(cachedClickTargets)
        if config.labelsOnlyMode || query.isEmpty {
            visibleTargets = allTargets
        } else {
            // Plain text search: type what you see (no keystroke lookup needed) and the
            // best-matching visible element is ranked first and auto-focused below, so a
            // single Enter click activates it directly. Matching is strictly against the
            // visible title text - NOT the assigned hint label - so a short query never
            // surfaces an unrelated element just because it happens to share letters with
            // that element's (arbitrary, not-memorable) keystroke code. Label-based jumps
            // are a fully separate path (Option+letter, see isLabelChar below).
            let lowerQuery = query.lowercased()
            let matches = allTargets.filter { target in
                target.title.lowercased().contains(lowerQuery)
            }
            visibleTargets = matches.sorted { lhs, rhs in
                queryMatchRank(lhs, query: lowerQuery) < queryMatchRank(rhs, query: lowerQuery)
            }
        }


        if visibleTargets.isEmpty {
            focusedIndex = 0
        } else if !query.isEmpty {
            // Always snap back to the top (best) match when the search text changes,
            // instead of leaving focus on a stale index from before typing.
            focusedIndex = 0
        } else {
            focusedIndex = focusedIndex % visibleTargets.count
        }

        render()
    }

    /// Lower rank = better match. Exact title match first, then titles starting with the
    /// query, then any other substring match (including label/text matches).
    private func queryMatchRank(_ target: HintTarget, query: String) -> Int {
        let title = target.title.lowercased()
        if title == query {
            return 0
        }
        if title.hasPrefix(query) {
            return 1
        }
        if title.contains(query) {
            return 2
        }
        return 3
    }

    private func timedScan() -> ClickScanResult {
        let scanStart = DispatchTime.now()
        let scan = scanner.scanClickableTargetsResult(maxCount: config.maxTargets, intensity: .fast)
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - scanStart.uptimeNanoseconds) / 1_000_000
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        print(String(format: "[Hackey] scan took %.1fms, found %d targets (app: %@, focusedFrame: %@)", elapsedMs, scan.targets.count, appName, String(describing: scan.focusedFrame)))
        return scan
    }

    private func render() {
        let focusedID = visibleTargets.isEmpty ? nil : visibleTargets[focusedIndex].id
        overlay.show(targets: visibleTargets, focusedID: focusedID, mode: mode, query: query, clipFrame: clickClipFrame)
    }

    private func handleClickMode(_ event: KeyEventSnapshot) {
        let key = event.key
        let modifiers = event.modifiers

        if key == "\u{1b}" {
            deactivate()
            return
        }

        if key == "\t" {
            moveFocus(delta: 1)
            return
        }

        if key == "\u{19}" {
            moveFocus(delta: -1)
            return
        }

        if key == "\r" {
            clickFocused(modifiers: modifiers)
            return
        }

        if key == "\u{7f}" {
            if !query.isEmpty {
                query.removeLast()
                refreshClickTargets(rescan: false)
            }
            return
        }

        // Label-jump (Option+letter) always takes priority as a label keystroke -
        // this is the PRIMARY interaction the badges are designed for (press the
        // exact key(s) shown on a badge to click it immediately), matching Vimium/
        // Homerow convention. Option is used (NOT Shift) specifically because it is
        // NEVER part of normal typed text - Shift is needed to type capital letters
        // (real page titles are almost always Title-Cased), so gating label-jump on
        // Shift made it fundamentally ambiguous with typing a capital letter as
        // part of a search phrase - no amount of clever fallback logic can fully
        // resolve that ambiguity because `HotkeyMonitor` always lowercases `key`
        // (`charactersIgnoringModifiers`), so Shift+letter and plain letter produce
        // the IDENTICAL `key` value. Option+letter has no such conflict: it's never
        // how anyone types plain search text, so this branch can safely take
        // priority unconditionally with zero ambiguity, on any page regardless of
        // how many targets/labels are currently visible.
        if modifiers.contains(.option), isLabelChar(key) {
            labelBuffer += key
            if let index = visibleTargets.firstIndex(where: { $0.label == labelBuffer }) {
                // Typing a hint label's full keystroke sequence must perform the
                // click immediately, matching how every other hint-mode tool
                // (Vimium, the original Homerow, etc.) behaves - the label IS the
                // click shortcut, not just a focus-move step that then requires a
                // separate Return press. Previously this only set focusedIndex and
                // rendered a highlighted badge, silently requiring an extra Enter
                // afterward; users reasonably expected the assigned keystroke to
                // act as the click and reported it as "not actually clicking."
                focusedIndex = index
                labelBuffer = ""
                clickFocused(modifiers: [])
                return
            }
            if visibleTargets.contains(where: { $0.label.hasPrefix(labelBuffer) }) {
                if let index = visibleTargets.firstIndex(where: { $0.label.hasPrefix(labelBuffer) }) {
                    focusedIndex = index
                    render()
                }
                return
            }
            // The Option-held letter doesn't extend any currently-visible label -
            // there's nothing useful to do with it (Option+letter was never valid
            // search-query input either), so just reset and drop it silently.
            labelBuffer = ""
            return
        }

        labelBuffer = ""
        // Allow bare Shift (needed to type capital letters and some punctuation)
        // through to the query - only reject genuine modifier combos like
        // Command/Option/Control, which are never part of normal typed text.
        let isPlainOrShiftOnly = modifiers.isEmpty || modifiers == .shift
        if !config.labelsOnlyMode, isQueryChar(key), isPlainOrShiftOnly {
            query += key
            refreshClickTargets(rescan: false)
            return
        }

    }

    private func clipTargetsToFocusedFrameIfAvailable(_ targets: [HintTarget]) -> [HintTarget] {
        guard let clickClipFrame else {
            return targets
        }

        let expanded = clickClipFrame.insetBy(dx: -16, dy: -16)
        let clipped = targets.filter { expanded.contains($0.point) }

        // Never silently show zero hints when the scanner already found real targets —
        // if the clip frame doesn't match (stale/mismatched window frame), fall back to
        // showing everything rather than leaving the user with an empty overlay.
        return clipped.isEmpty ? targets : clipped
    }

    private func clickFocused(modifiers: NSEvent.ModifierFlags) {
        guard !visibleTargets.isEmpty else {
            return
        }

        let target = visibleTargets[focusedIndex]
        // Re-read the element's position live rather than trusting the point captured
        // at scan time - anything (scroll, lazy render, hover/expand animation, time
        // spent typing a search query) can shift the page between scan and click, and
        // a stale coordinate silently clicks whatever now sits at that old pixel
        // instead of the intended element. Falls back to the scanned point only if the
        // element no longer resolves a live position (e.g. it was removed from the tree).
        let point = scanner.currentPoint(for: target.axElement) ?? target.point
        if modifiers.contains(.shift) {
            performer.rightClick(at: point)
        } else if modifiers.contains(.command) {
            performer.commandClick(at: point)
        } else if target.role == "AXGroup" {
            // Finder's icon-grid entries (Desktop, Applications folder, etc.) need a
            // real double-click to open - a single click only selects/highlights them,
            // matching what a person would do by hand.
            performer.doubleLeftClick(at: point)
        } else {
            performer.leftClick(at: point)
        }

        deactivate()
    }

    private func handleScrollMode(_ event: KeyEventSnapshot) {
        let key = event.key

        if key == "\u{1b}" {
            deactivate()
            return
        }

        if key == "\t" {
            moveFocus(delta: 1)
            return
        }

        if key == "\u{19}" {
            moveFocus(delta: -1)
            return
        }

        if let digit = Int(key), !visibleTargets.isEmpty {
            focusedIndex = min(digit, visibleTargets.count - 1)
            render()
            return
        }

        switch key {
        case "h":
            performer.scroll(deltaX: -scrollSpeed, deltaY: 0)
        case "j":
            performer.scroll(deltaX: 0, deltaY: -scrollSpeed)
        case "k":
            performer.scroll(deltaX: 0, deltaY: scrollSpeed)
        case "l":
            performer.scroll(deltaX: scrollSpeed, deltaY: 0)
        default:
            return
        }
    }

    private func moveFocus(delta: Int) {
        guard !visibleTargets.isEmpty else {
            return
        }
        let count = visibleTargets.count
        focusedIndex = (focusedIndex + delta + count) % count
        render()
    }

    private func isQueryChar(_ key: String) -> Bool {
        guard let scalar = key.unicodeScalars.first else {
            return false
        }
        return CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " _-./")).contains(scalar)
    }

    private func isLabelChar(_ key: String) -> Bool {
        guard let scalar = key.unicodeScalars.first else {
            return false
        }
        return CharacterSet.letters.contains(scalar)
    }

    private func shouldDropDuplicate(_ event: KeyEventSnapshot) -> Bool {
        let now = Date().timeIntervalSince1970
        let fingerprint = "\(event.keyCode)-\(event.modifiersRawValue)-\(event.key)-\(event.isRepeat)"
        // Only HotkeyMonitor's single global NSEvent monitor delivers key events, so a
        // genuine double-delivery (the same physical keydown handed to us twice) would
        // show up back-to-back within the same runloop tick — well under a millisecond.
        // The previous 30ms window was wide enough to also swallow legitimate fast
        // double-letter typing (e.g. typing "wesstream" search text would silently lose
        // the second "s"), which broke the plain-text search feature. 3ms still catches
        // real duplicate delivery without eating intentional repeated keystrokes.
        let isDuplicate = fingerprint == lastEventFingerprint && (now - lastEventAt) < 0.003
        lastEventFingerprint = fingerprint
        lastEventAt = now
        return isDuplicate
    }
}
