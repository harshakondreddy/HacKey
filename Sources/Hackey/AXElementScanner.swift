import AppKit
import ApplicationServices
import CoreGraphics
import Dispatch
import Foundation

enum ScanIntensity {
    case fast
    case full
}

struct ClickScanResult {
    let targets: [HintTarget]
    let focusedFrame: CGRect?
}

final class AXElementScanner {
    private let childAttributeKeys: [String] = [
        kAXChildrenAttribute as String,
        "AXVisibleChildren",
        "AXContents",
        "AXRows",
        "AXSelectedChildren",
        "AXTabs"
    ]

    /// Roles that are pure containers and never actionable themselves. Skipping the
    /// AXUIElementCopyActionNames IPC call entirely for these (instead of calling it
    /// unconditionally on every node) is one of the biggest wins for scan speed on
    /// deep trees like Finder's list view with hundreds of rows.
    private let containerRolesToSkip: Set<String> = [
        "AXMenuBarItem",
        "AXWindow",
        "AXApplication",
        "AXScrollArea",
        "AXWebArea",
        "AXGroup",
        "AXUnknown"
    ]

    private let searchPredicatePreferredBundles: Set<String> = [
        "com.microsoft.teams2",
        "com.microsoft.edgemac",
        "com.google.Chrome",
        "com.brave.Browser",
        "company.thebrowser.Browser",
        "com.operasoftware.Opera",
        "com.github.wez.wezterm",
        "com.tinyspeck.slackmacgap",
        "com.spotify.client",
        "com.microsoft.VSCode"
    ]

    func scanClickableTargets(maxCount: Int) -> [HintTarget] {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return []
        }

        return scanClickableTargetsResult(for: app, maxCount: maxCount, intensity: .fast).targets
    }

    /// Re-reads an element's CURRENT on-screen position directly from the live
    /// AXUIElement (fresh AXPosition/AXSize), instead of trusting the point captured
    /// at scan time. Coordinate-based clicks (used whenever kAXPressAction isn't
    /// supported, e.g. many web AXRow/AXCell targets) MUST use this right before
    /// clicking - anything can shift a page's layout between when the overlay was
    /// scanned and when the user actually presses Enter/a label (scrolling, lazy
    /// content loading, a hover/expand animation, even just typing a longer search
    /// query while looking at the results) and a stale point silently clicks
    /// whatever now happens to sit at that old pixel instead of the intended element.
    func currentPoint(for element: AXUIElement) -> CGPoint? {
        centerPoint(of: element)
    }

    func scanClickableTargetsResult(maxCount: Int, intensity: ScanIntensity = .fast) -> ClickScanResult {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return ClickScanResult(targets: [], focusedFrame: nil)
        }
        return scanClickableTargetsResult(for: app, maxCount: maxCount, intensity: intensity)
    }

    func scanClickableTargets(for app: NSRunningApplication, maxCount: Int, intensity: ScanIntensity = .fast) -> [HintTarget] {
        return scanClickableTargetsResult(for: app, maxCount: maxCount, intensity: intensity).targets
    }

    func scanClickableTargetsResult(for app: NSRunningApplication, maxCount: Int, intensity: ScanIntensity = .fast) -> ClickScanResult {
        let bundleID = app.bundleIdentifier ?? ""
        let preferSearchPredicate = shouldUseSearchPredicateFallback(bundleID: bundleID)
        let includeDiscoveredAttributes = intensity == .full
        // Modern Electron/Chromium apps (Teams, Slack, VS Code) often nest their real
        // content many AXGroup layers deep before reaching the AXWebArea (or the actual
        // AXButton/AXRow elements) that we care about. A too-shallow depth limit meant
        // the search-predicate fallback below never even got a chance to fire because we
        // gave up walking the tree before reaching it. The 700ms deadline + hardLimit
        // still bound worst-case latency, so it's safe to go deeper.
        let maxDepth = intensity == .full ? 14 : 12
        let hardLimit = intensity == .full ? maxCount * 10 : maxCount * 4
        // Hard wall-clock budget so scan latency stays consistent regardless of how many
        // off-screen rows a big list (e.g. Applications folder) happens to expose via AX.
        // Kept generous enough that real window content isn't cut off before it's reached.
        let deadline = DispatchTime.now() + .milliseconds(intensity == .full ? 1500 : 700)

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        enableManualAccessibility(on: appElement)
        let windows = copyArrayAttribute(appElement, key: kAXWindowsAttribute as String)
        let realWindows = windows.filter { !isDesktopLikeWindow($0) }

        var roots: [AXUIElement] = []
        var focusedFrame: CGRect?
        if let focusedWindow = copyElementAttribute(appElement, key: kAXFocusedWindowAttribute as String),
           !isDesktopLikeWindow(focusedWindow) {
            roots.append(focusedWindow)
            focusedFrame = frame(of: focusedWindow)
        }

        if let mainWindow = copyElementAttribute(appElement, key: kAXMainWindowAttribute as String),
           !isDesktopLikeWindow(mainWindow),
           !roots.contains(where: { CFEqual($0, mainWindow) }) {
            roots.append(mainWindow)
            if focusedFrame == nil {
                focusedFrame = frame(of: mainWindow)
            }
        }

        if roots.isEmpty {
            roots = realWindows
        }

        if focusedFrame == nil {
            focusedFrame = realWindows.compactMap { frame(of: $0) }.max(by: { lhs, rhs in
                (lhs.width * lhs.height) < (rhs.width * rhs.height)
            })
        }

        if focusedFrame == nil {
            focusedFrame = cgWindowFrame(for: app.processIdentifier)
        }

        guard focusedFrame != nil else {
            return ClickScanResult(targets: [], focusedFrame: nil)
        }

        var rawTargets: [(AXUIElement, CGPoint, String, String, CGRect?)] = []
        // Expand a little beyond the visible window bounds so edge-anchored controls
        // (e.g. scrollbars, resize handles) aren't pruned, while still skipping the vast
        // majority of off-screen rows in huge scrollable lists.
        let clipFrame = focusedFrame?.insetBy(dx: -40, dy: -40)

        for root in roots {
            scanChildren(
                root,
                depth: 0,
                maxDepth: maxDepth,
                rawTargets: &rawTargets,
                hardLimit: hardLimit,
                preferSearchPredicate: preferSearchPredicate,
                includeDiscoveredAttributes: includeDiscoveredAttributes,
                clipFrame: clipFrame,
                deadline: deadline
            )
            if rawTargets.count >= hardLimit {
                break
            }
        }

        let deduped = dedupe(rawTargets)
        let filtered = filterByFocusedWindowIfAvailable(deduped, focusedFrame: focusedFrame)
        let qualityFiltered = filterLowValueContainerTargets(filtered)
        let frameFiltered = filterByElementFrameQuality(qualityFiltered, focusedFrame: focusedFrame)
        let finalTargets = Array(frameFiltered.prefix(maxCount))
        let labels = Self.makeLabels(count: finalTargets.count)

        let mappedTargets = zip(finalTargets, labels).map { item, label in
            HintTarget(axElement: item.0, point: item.1, title: item.2, role: item.3, label: label, elementFrame: item.4)
        }

        return ClickScanResult(targets: mappedTargets, focusedFrame: focusedFrame)
    }

    func diagnosticsSummary(maxCount: Int) -> String {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return "Clickable targets: 0\nTop roles: none"
        }
        return diagnosticsSummary(for: app, maxCount: maxCount)
    }

    func diagnosticsSummary(for app: NSRunningApplication, maxCount: Int) -> String {
        let targets = scanClickableTargets(for: app, maxCount: maxCount, intensity: .full)
        let roleHistogram = Dictionary(grouping: targets, by: { $0.role }).mapValues { $0.count }
        let topRoles = roleHistogram
            .sorted { $0.value > $1.value }
            .prefix(8)
            .map { "\($0.key): \($0.value)" }
            .joined(separator: ", ")
        let roleSummary = topRoles.isEmpty ? "none" : topRoles

        return "Clickable targets: \(targets.count)\nTop roles: \(roleSummary)"
    }

    func scanScrollAreas(maxCount: Int = 20) -> [HintTarget] {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return []
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let windows = copyArrayAttribute(appElement, key: kAXWindowsAttribute as String)
        var areas: [(AXUIElement, CGPoint, String, String, CGRect?)] = []

        for window in windows {
            scanScrollable(window, depth: 0, maxDepth: 6, out: &areas, hardLimit: maxCount * 3)
            if areas.count >= maxCount * 3 {
                break
            }
        }

        // Scroll-mode selection only ever reads a single digit key (0-9), so any target
        // beyond the 10th is both unreachable by keystroke AND would be assigned a
        // duplicate label (`makeNumericLabels` wraps with `% 10`). Cap at 10 to guarantee
        // every visible badge is unique and directly reachable.
        let cappedCount = min(maxCount, 10)
        let deduped = dedupe(areas).prefix(cappedCount)
        let labels = Self.makeNumericLabels(count: deduped.count)
        return zip(deduped, labels).map { item, label in
            HintTarget(axElement: item.0, point: item.1, title: item.2, role: item.3, label: label, elementFrame: item.4)
        }
    }

    private func scanChildren(
        _ element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        rawTargets: inout [(AXUIElement, CGPoint, String, String, CGRect?)],
        hardLimit: Int,
        preferSearchPredicate: Bool,
        includeDiscoveredAttributes: Bool,
        clipFrame: CGRect?,
        deadline: DispatchTime
    ) {
        if rawTargets.count >= hardLimit || depth > maxDepth || DispatchTime.now() >= deadline {
            return
        }

        let role = normalizeRole(copyStringAttribute(element, key: kAXRoleAttribute as String))
        let elementFrame = frame(of: element)

        // Prune entire subtrees that fall outside the focused window's bounds before
        // paying the IPC cost of walking into their children. This is what keeps scan
        // time roughly constant even when a list (e.g. Finder's Applications view)
        // materializes hundreds of off-screen AX rows.
        if let clipFrame, let elementFrame, !clipFrame.intersects(elementFrame) {
            return
        }

        let isIgnoredContainer = role.map { containerRolesToSkip.contains($0) } ?? false
        let actions = isIgnoredContainer ? [] : copyActionNames(element)

        // Finder's icon-view items (file/app icons in Desktop, Applications folder, etc.)
        // are exposed as a plain "AXGroup" with NO AXPress/other action AND no fallback
        // role match, so isActionable() rejected every single one of them - the entire
        // icon grid silently produced zero targets even though extractTitle correctly
        // reads each icon's name (e.g. "Visual Studio Code.app"). The distinguishing
        // trait vs. an ordinary layout/wrapper AXGroup (e.g. a toolbar section) is that
        // real icon items are direct children of an "AXList" (the grid container) -
        // checking the parent's role is a structural signal that generalizes to any
        // icon-grid-style UI, not just Finder specifically.
        let isIconGridEntry = role == "AXGroup" && parentRole(of: element) == "AXList"

        if (isActionable(role: role, actions: actions) || isIconGridEntry), let point = centerPoint(of: element) {
            let title = extractTitle(for: element)
            rawTargets.append((element, point, title, role ?? "", elementFrame))
        }

        if preferSearchPredicate && role == "AXWebArea" {
            let searchChildren = copySearchPredicateDescendants(of: element)
            for child in searchChildren {
                if rawTargets.count >= hardLimit {
                    return
                }
                let childRole = normalizeRole(copyStringAttribute(child, key: kAXRoleAttribute as String))
                let childActions = copyActionNames(child)
                guard isActionable(role: childRole, actions: childActions),
                      let point = centerPoint(of: child) else {
                    continue
                }
                let title = extractTitle(for: child)
                rawTargets.append((child, point, title, childRole ?? "", frame(of: child)))
            }
        }

        // Visit larger children first. Real window content (icon grids, lists, web areas)
        // is almost always much larger in area than toolbar buttons or sidebar rows, so
        // this ensures the scan budget is spent on actual content instead of being
        // exhausted while still walking through window chrome.
        let children = copyChildElements(element, includeDiscoveredAttributes: includeDiscoveredAttributes)
        let orderedChildren = children.sorted { lhs, rhs in
            let lhsArea = frame(of: lhs).map { $0.width * $0.height } ?? 0
            let rhsArea = frame(of: rhs).map { $0.width * $0.height } ?? 0
            return lhsArea > rhsArea
        }

        for child in orderedChildren {
            scanChildren(
                child,
                depth: depth + 1,
                maxDepth: maxDepth,
                rawTargets: &rawTargets,
                hardLimit: hardLimit,
                preferSearchPredicate: preferSearchPredicate,
                includeDiscoveredAttributes: includeDiscoveredAttributes,
                clipFrame: clipFrame,
                deadline: deadline
            )
            if rawTargets.count >= hardLimit || DispatchTime.now() >= deadline {
                return
            }
        }
    }

    private func scanScrollable(
        _ element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        out: inout [(AXUIElement, CGPoint, String, String, CGRect?)],
        hardLimit: Int
    ) {
        if out.count >= hardLimit || depth > maxDepth {
            return
        }

        let role = normalizeRole(copyStringAttribute(element, key: kAXRoleAttribute as String)) ?? ""
        if isScrollable(role: role), let point = centerPoint(of: element) {
            out.append((element, point, role, role, frame(of: element)))
        }

        for child in copyChildElements(element) {
            scanScrollable(child, depth: depth + 1, maxDepth: maxDepth, out: &out, hardLimit: hardLimit)
            if out.count >= hardLimit {
                return
            }
        }
    }

    private func isActionable(role: String?, actions: [String]) -> Bool {
        guard let role = normalizeRole(role) else {
            return false
        }

        if containerRolesToSkip.contains(role) {
            return false
        }

        let ignoredActions: Set<String> = [
            "AXShowMenu",
            "AXScrollToVisible",
            "AXShowDefaultUI",
            "AXShowAlternateUI",
            "AXRaise",
            "AXCancel",
            "AXDelete",
            "AXSetValue"
        ]
        let actionSet = Set(actions).subtracting(ignoredActions)

        if actionSet.contains(kAXPressAction as String)
            || actionSet.contains("AXConfirm")
            || actionSet.contains("AXPick") {
            return true
        }

        // Lightweight fallback for apps that under-report AXPress on otherwise clickable controls.
        // AXRow/AXDisclosureTriangle matter a lot here: Finder's file list *and* sidebar,
        // Mail's message list, Xcode's navigator, System Settings groups, etc. are all built from
        // AXRow items that frequently don't advertise kAXPressAction even though clicking them
        // absolutely works. Without this, entire list-based UIs can silently produce zero targets.
        // (AXCell is deliberately excluded: it's usually a child of AXRow at ~the same point and
        // would just produce a visually duplicate badge stacked on top of the row's badge.)
        let fallbackRoles: Set<String> = [
            "AXButton",
            "AXLink",
            "AXCheckBox",
            "AXRadioButton",
            "AXPopUpButton",
            "AXComboBox",
            "AXMenuItem",
            "AXTab",
            "AXRow",
            "AXDisclosureTriangle"
        ]
        return fallbackRoles.contains(role)
    }

    private func isScrollable(role: String) -> Bool {
        return role == kAXScrollAreaRole as String
            || role == "AXWebArea"
            || role == kAXListRole as String
            || role == kAXTableRole as String
            || role == kAXOutlineRole as String
            || role == kAXTextAreaRole as String
    }

    private func centerPoint(of element: AXUIElement) -> CGPoint? {
        guard let positionValue = copyAXValueAttribute(element, key: kAXPositionAttribute as String),
              let sizeValue = copyAXValueAttribute(element, key: kAXSizeAttribute as String) else {
            return nil
        }

        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetType(positionValue) == .cgPoint,
              AXValueGetValue(positionValue, .cgPoint, &point),
              AXValueGetType(sizeValue) == .cgSize,
              AXValueGetValue(sizeValue, .cgSize, &size),
              size.width > 4,
              size.height > 4 else {
            return nil
        }

        return CGPoint(x: point.x + (size.width / 2), y: point.y + (size.height / 2))
    }

    private func dedupe(_ list: [(AXUIElement, CGPoint, String, String, CGRect?)]) -> [(AXUIElement, CGPoint, String, String, CGRect?)] {
        var seen = Set<String>()
        var out: [(AXUIElement, CGPoint, String, String, CGRect?)] = []
        for item in list {
            let bucketX = Int(item.1.x / 3.0)
            let bucketY = Int(item.1.y / 3.0)
            let key = "\(bucketX)-\(bucketY)-\(item.3)"
            if seen.insert(key).inserted {
                out.append(item)
            }
        }
        return out
    }

    private func filterByFocusedWindowIfAvailable(
        _ targets: [(AXUIElement, CGPoint, String, String, CGRect?)],
        focusedFrame: CGRect?
    ) -> [(AXUIElement, CGPoint, String, String, CGRect?)] {
        guard let focusedFrame else {
            return []
        }

        let expanded = focusedFrame.insetBy(dx: -24, dy: -24)
        let inside = targets.filter { expanded.contains($0.1) }
        return inside.isEmpty ? targets : inside
    }

    private func filterLowValueContainerTargets(
        _ targets: [(AXUIElement, CGPoint, String, String, CGRect?)]
    ) -> [(AXUIElement, CGPoint, String, String, CGRect?)] {
        // "AXGroup" is normally skipped here since it's almost always a pure layout
        // wrapper - EXCEPT any AXGroup that made it this far can only have gotten into
        // the target list via the isIconGridEntry check in scanChildren (icon-view
        // items like Finder's Applications/Desktop icons, exposed as a titled AXGroup
        // whose parent is an AXList). Filtering those back out here would silently
        // re-break the exact icon-grid coverage that check exists to fix.
        let rolesToSkip = containerRolesToSkip.subtracting(["AXGroup"])
        return targets.filter { item in
            let role = normalizeRole(item.3) ?? item.3
            return !rolesToSkip.contains(role)
        }
    }

    private func filterByElementFrameQuality(
        _ targets: [(AXUIElement, CGPoint, String, String, CGRect?)],
        focusedFrame: CGRect?
    ) -> [(AXUIElement, CGPoint, String, String, CGRect?)] {
        guard let focusedFrame else {
            return targets
        }

        let maxArea = focusedFrame.width * focusedFrame.height * 0.65
        let filtered = targets.filter { item in
            // Reuse the frame captured during traversal instead of paying for another
            // AX IPC round trip here.
            guard let frame = item.4 ?? frame(of: item.0) else {
                return true
            }
            let area = frame.width * frame.height
            if area > maxArea {
                return false
            }
            if frame.width < 6 || frame.height < 6 {
                return false
            }
            return frame.intersects(focusedFrame.insetBy(dx: -20, dy: -20))
        }

        // Same defensive fallback as the other focused-frame filters: a mismatched or
        // stale focusedFrame (e.g. from the CGWindowList fallback picking a different
        // window than the one actually traversed) must never wipe out every real target
        // we already found.
        return filtered.isEmpty ? targets : filtered
    }

    private func normalizeRole(_ role: String?) -> String? {
        role?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Finder (and some other apps) expose a hidden full-screen "Desktop" AXWindow
    /// alongside real user-facing windows. Picking it up as the focused/root window
    /// causes labels to scatter across desktop-icon coordinates instead of the
    /// actual visible window. Filter those out using title and full-screen-size heuristics.
    private func isDesktopLikeWindow(_ element: AXUIElement) -> Bool {
        let title = copyStringAttribute(element, key: kAXTitleAttribute as String)?.lowercased() ?? ""
        let subrole = copyStringAttribute(element, key: kAXSubroleAttribute as String) ?? ""

        if title == "desktop" || subrole == "AXSystemDialog" {
            return true
        }

        guard let elementFrame = frame(of: element) else {
            return false
        }

        let coveredByAnyScreen = NSScreen.screens.contains { screen in
            let screenArea = screen.frame.width * screen.frame.height
            guard screenArea > 0 else { return false }
            let overlap = screen.frame.intersection(elementFrame)
            let overlapArea = overlap.width * overlap.height
            return overlapArea >= screenArea * 0.95
        }

        // A window that exactly blankets an entire screen and has no title is almost
        // certainly a desktop/background element rather than a real focusable window.
        return coveredByAnyScreen && title.isEmpty
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue = copyAXValueAttribute(element, key: kAXPositionAttribute as String),
              let sizeValue = copyAXValueAttribute(element, key: kAXSizeAttribute as String) else {
            return nil
        }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetType(positionValue) == .cgPoint,
              AXValueGetValue(positionValue, .cgPoint, &origin),
              AXValueGetType(sizeValue) == .cgSize,
              AXValueGetValue(sizeValue, .cgSize, &size),
              size.width > 10,
              size.height > 10 else {
            return nil
        }

        return CGRect(origin: origin, size: size)
    }

    private func copyArrayAttribute(_ element: AXUIElement, key: String) -> [AXUIElement] {
        var raw: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, key as CFString, &raw)
        guard result == .success, let arr = raw as? [AXUIElement] else {
            return []
        }
        return arr
    }

    private func copyElementAttribute(_ element: AXUIElement, key: String) -> AXUIElement? {
        var raw: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, key as CFString, &raw)
        guard result == .success else {
            return nil
        }
        return raw as! AXUIElement?
    }

    private func parentRole(of element: AXUIElement) -> String? {
        guard let parent = copyElementAttribute(element, key: kAXParentAttribute as String) else {
            return nil
        }
        return normalizeRole(copyStringAttribute(parent, key: kAXRoleAttribute as String))
    }

    private func copyChildElements(_ element: AXUIElement, includeDiscoveredAttributes: Bool = false) -> [AXUIElement] {
        var merged: [AXUIElement] = []
        var seen = Set<CFHashCode>()

        func appendUnique(_ value: AXUIElement) {
            let hash = CFHash(value)
            if seen.insert(hash).inserted {
                merged.append(value)
            }
        }

        for key in childAttributeKeys {
            let values = copyArrayAttribute(element, key: key)
            for value in values {
                appendUnique(value)
            }
        }

        if includeDiscoveredAttributes {
            for key in copyAttributeNames(element) {
                let values = copyArrayAttribute(element, key: key)
                if values.isEmpty {
                    continue
                }
                for value in values {
                    appendUnique(value)
                }
            }
        }

        return merged
    }

    private func copyAttributeNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        let result = AXUIElementCopyAttributeNames(element, &names)
        guard result == .success, let arr = names as? [String] else {
            return []
        }
        return arr
    }

    private func copySearchPredicateDescendants(of element: AXUIElement) -> [AXUIElement] {
        let queryBase: [String: Any] = [
            "AXDirection": "AXDirectionNext",
            "AXImmediateDescendantsOnly": false,
            "AXResultsLimit": -1,
            "AXVisibleOnly": true
        ]

        let searchKeys: [Any] = [
            "AXButtonSearchKey",
            "AXCheckBoxSearchKey",
            "AXControlSearchKey",
            "AXGraphicSearchKey",
            "AXLinkSearchKey",
            "AXRadioGroupSearchKey",
            "AXTextFieldSearchKey"
        ]

        var allMatches: [AXUIElement] = []

        var multiQuery = queryBase
        multiQuery["AXSearchKey"] = searchKeys
        allMatches.append(contentsOf: copyParameterizedElementArray(
            element,
            parameterizedAttribute: "AXUIElementsForSearchPredicate",
            parameter: multiQuery
        ))

        if allMatches.isEmpty {
            for key in searchKeys {
                var singleQuery = queryBase
                singleQuery["AXSearchKey"] = key
                allMatches.append(contentsOf: copyParameterizedElementArray(
                    element,
                    parameterizedAttribute: "AXUIElementsForSearchPredicate",
                    parameter: singleQuery
                ))
            }
        }

        var unique: [AXUIElement] = []
        var seen = Set<CFHashCode>()
        for item in allMatches {
            let hash = CFHash(item)
            if seen.insert(hash).inserted {
                unique.append(item)
            }
        }

        return unique
    }

    private func copyParameterizedElementArray(
        _ element: AXUIElement,
        parameterizedAttribute: String,
        parameter: [String: Any]
    ) -> [AXUIElement] {
        var raw: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(
            element,
            parameterizedAttribute as CFString,
            parameter as CFTypeRef,
            &raw
        )
        guard result == .success, let arr = raw as? [AXUIElement] else {
            return []
        }
        return arr
    }

    private func enableManualAccessibility(on appElement: AXUIElement) {
        _ = AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    private func shouldUseSearchPredicateFallback(bundleID: String) -> Bool {
        if searchPredicatePreferredBundles.contains(bundleID) {
            return true
        }
        return bundleID.lowercased().contains("microsoft")
            || bundleID.lowercased().contains("chrome")
            || bundleID.lowercased().contains("slack")
            || bundleID.lowercased().contains("electron")
            || bundleID.lowercased().contains("code")
    }

    private func cgWindowFrame(for pid: pid_t) -> CGRect? {
        guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for info in infoList {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int,
                  ownerPID == Int(pid),
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let alpha = info[kCGWindowAlpha as String] as? Double,
                  alpha > 0,
                                    let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                                    let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width > 50,
                  bounds.height > 50 else {
                continue
            }
            return bounds
        }

        return nil
    }

    private func copyActionNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        let result = AXUIElementCopyActionNames(element, &names)
        guard result == .success, let arr = names as? [String] else {
            return []
        }
        return arr
    }

    private func copyStringAttribute(_ element: AXUIElement, key: String) -> String? {
        var raw: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, key as CFString, &raw)
        guard result == .success, let value = raw as? String else {
            return nil
        }
        return value
    }

    /// Title/description/value can each be *successfully fetched but empty* (e.g. many
    /// web `AXRow`/`AXCell` elements report AXTitle == "" rather than nil). Swift's `??`
    /// only falls through on `nil`, so a naive `a ?? b ?? c` chain would stop at the
    /// first empty-but-non-nil result and never reach the attribute that actually holds
    /// the visible text. Explicitly skip empty strings at each step instead.
    private func extractTitle(for element: AXUIElement) -> String {
        if let title = copyStringAttribute(element, key: kAXTitleAttribute as String), !title.isEmpty {
            return title
        }
        if let description = copyStringAttribute(element, key: kAXDescriptionAttribute as String), !description.isEmpty {
            return description
        }
        if let value = copyStringAttribute(element, key: kAXValueAttribute as String), !value.isEmpty {
            return value
        }
        // Rows/containers (e.g. a Chrome data-grid AXRow, a Finder AXRow) frequently have
        // no title/description/value of their own — the real visible text lives on
        // descendant AXStaticText/AXCell elements instead. Walk a few levels down and
        // stitch together whatever text we find as a last resort so search/query
        // matching has something meaningful to work with.
        return descendantText(of: element, maxDepth: 3, maxLength: 160)
    }

    private func descendantText(of element: AXUIElement, maxDepth: Int, maxLength: Int) -> String {
        var pieces: [String] = []
        var visitedCount = 0
        let visitLimit = 40

        func visit(_ node: AXUIElement, depth: Int) {
            if depth > maxDepth || visitedCount >= visitLimit {
                return
            }
            let children = copyChildElements(node, includeDiscoveredAttributes: false)
            for child in children {
                visitedCount += 1
                if visitedCount >= visitLimit {
                    return
                }
                let childRole = normalizeRole(copyStringAttribute(child, key: kAXRoleAttribute as String))
                let text = copyStringAttribute(child, key: kAXValueAttribute as String)
                    ?? copyStringAttribute(child, key: kAXTitleAttribute as String)
                    ?? copyStringAttribute(child, key: kAXDescriptionAttribute as String)
                if let text, !text.isEmpty, childRole != "AXRow" {
                    pieces.append(text)
                }
                if pieces.joined(separator: " ").count >= maxLength {
                    return
                }
                visit(child, depth: depth + 1)
            }
        }

        visit(element, depth: 0)
        let joined = pieces.joined(separator: " ")
        return joined.count > maxLength ? String(joined.prefix(maxLength)) : joined
    }

    private func copyAXValueAttribute(_ element: AXUIElement, key: String) -> AXValue? {
        var raw: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, key as CFString, &raw)
        guard result == .success, let value = raw else {
            return nil
        }
        guard CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        return (value as! AXValue)
    }

    static func makeLabels(count: Int) -> [String] {
        guard count > 0 else {
            return []
        }

        let alphabet = Array("asdfjklghqwertyuiopzxcvbnm")
        let base = alphabet.count
        // All labels in a batch MUST be the same fixed length. A bijective
        // variable-length scheme (like Excel columns: a, b, ... z, aa, ab, ...)
        // gives the first `base` targets a single-character label and every
        // target after that a two-character label - but that is NOT a
        // prefix-free set ("a" is a literal prefix of "aa"), so typing "a"
        // immediately commits to the single-letter target (see the exact-match
        // check in HackeyCoordinator.handleClickMode) before a second keystroke
        // can ever be read. Every longer label sharing that first letter becomes
        // permanently unreachable by keystroke - this was a real, major bug:
        // once a window/page had more than 26 targets, dozens of assigned
        // "keystrokes" silently could never be typed, and pressing what looked
        // like a valid single-letter label for a *different* target (whose
        // first letter happened to collide) would appear to work while actually
        // being ambiguous. Using one fixed width for the whole batch (computed
        // from the total count) sidesteps this entirely: no fixed-length string
        // can ever be a prefix of another string of the same length.
        var width = 1
        while pow(Double(base), Double(width)) < Double(count) {
            width += 1
        }

        var labels: [String] = []
        labels.reserveCapacity(count)
        for i in 0..<count {
            labels.append(fixedWidthLabel(for: i, width: width, alphabet: alphabet))
        }
        return labels
    }

    static func makeNumericLabels(count: Int) -> [String] {
        return (0..<count).map { String($0 % 10) }
    }

    private static func fixedWidthLabel(for value: Int, width: Int, alphabet: [Character]) -> String {
        let base = alphabet.count
        var n = value
        var chars: [Character] = []

        for _ in 0..<width {
            chars.append(alphabet[n % base])
            n /= base
        }

        return String(chars.reversed())
    }
}
