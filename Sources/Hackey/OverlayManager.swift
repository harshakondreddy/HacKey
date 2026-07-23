import AppKit
import Foundation

@MainActor
final class OverlayManager {
    private var windows: [NSScreen: OverlayWindow] = [:]

    func show(targets: [HintTarget], focusedID: UUID?, mode: HackeyMode, query: String, clipFrame: CGRect?) {
        ensureWindows()
        for (screen, window) in windows {
            let onScreenTargets = targets.filter { screen.frame.contains($0.point) }
            // Clip to the focused window's frame when we have one, but never let a
            // stale/mismatched clip frame silently hide real targets that the scanner
            // already found and placed on this screen.
            let clipped = clipFrame.map { frame in onScreenTargets.filter { frame.contains($0.point) } } ?? onScreenTargets
            let localTargets = clipped.isEmpty ? onScreenTargets : clipped
            window.update(targets: localTargets, focusedID: focusedID, mode: mode, query: query)
            if !window.isVisible {
                window.orderFrontRegardless()
            }
        }
    }

    func hide() {
        for window in windows.values {
            window.orderOut(nil)
        }
    }

    private func ensureWindows() {
        for screen in NSScreen.screens where windows[screen] == nil {
            windows[screen] = OverlayWindow(screen: screen)
        }

        let existing = Set(windows.keys)
        let current = Set(NSScreen.screens)
        let removed = existing.subtracting(current)
        for screen in removed {
            windows.removeValue(forKey: screen)
        }
    }
}

final class OverlayWindow: NSWindow {
    private let canvas = OverlayCanvasView()

    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = canvas
    }

    func update(targets: [HintTarget], focusedID: UUID?, mode: HackeyMode, query: String) {
        canvas.targets = targets
        canvas.focusedID = focusedID
        canvas.mode = mode
        canvas.query = query
        canvas.totalTargetCount = targets.count
        canvas.needsDisplay = true
    }
}

final class OverlayCanvasView: NSView {
    var targets: [HintTarget] = []
    var focusedID: UUID?
    var mode: HackeyMode = .idle
    var query: String = ""
    var totalTargetCount: Int = 0

    override var isFlipped: Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()

        for target in targets {
            drawLabel(for: target)
        }

        drawHUD()
    }

    private func drawLabel(for target: HintTarget) {
        let anchor = labelAnchorPoint(for: target)
        let text = target.label.uppercased()
        let isFocused = target.id == focusedID

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
            .foregroundColor: NSColor.black
        ]

        let size = text.size(withAttributes: attrs)
        // Font size is fixed above. Padding is intentionally asymmetric: a bit more
        // horizontal breathing room so 2-letter labels (e.g. "AS", "DJ") don't look
        // cramped/thin, while vertical padding stays tight so the badge doesn't grow
        // into a big square around the text.
        let paddingX: CGFloat = 3.5
        let paddingY: CGFloat = 1.5
        let width = size.width + paddingX * 2
        let height = size.height + paddingY
        let rect = NSRect(
            x: anchor.x - width / 2,
            y: anchor.y - height / 2,
            width: width,
            height: height
        )

        // A fixed, light-gray badge (rather than yellow/black) reads clearly against both
        // light and dark app content without needing to track system appearance, and the
        // dark stroke keeps it visible even against near-white backgrounds.
        let background = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        (isFocused ? NSColor.systemGreen : Self.hintBadgeColor).setFill()
        background.fill()
        NSColor.black.withAlphaComponent(0.55).setStroke()
        background.lineWidth = 1.0
        background.stroke()

        text.draw(at: NSPoint(x: rect.minX + paddingX, y: rect.minY + paddingY / 2), withAttributes: attrs)
    }

    /// Anchors the badge to the element's top-right corner (instead of dead-center) so
    /// it doesn't cover the icon/text it's labeling. Falls back to the raw center point
    /// when the scanner couldn't determine the element's frame.
    private func labelAnchorPoint(for target: HintTarget) -> CGPoint {
        guard let frame = target.elementFrame else {
            return convertFromGlobal(target.point)
        }
        let topRightGlobal = CGPoint(x: frame.maxX, y: frame.minY)
        return convertFromGlobal(topRightGlobal)
    }

    // Light gray, leaning toward white, with high contrast against both light and dark
    // backgrounds. The black outline (above) keeps it readable even on white content.
    private static let hintBadgeColor = NSColor(calibratedWhite: 0.88, alpha: 0.97)


    private func drawHUD() {
        let modeText: String
        switch mode {
        case .idle:
            modeText = "IDLE"
        case .click:
            modeText = "CLICK"
        case .scroll:
            modeText = "SCROLL"
        }

        let base = "Hackey • \(modeText) • \(totalTargetCount)"
        let text = query.isEmpty ? base : "\(base) • \(query)"

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white
        ]

        let size = text.size(withAttributes: attrs)
        let rect = NSRect(x: 20, y: 20, width: size.width + 20, height: 28)
        let bg = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        NSColor.black.withAlphaComponent(0.75).setFill()
        bg.fill()

        text.draw(at: NSPoint(x: rect.minX + 10, y: rect.minY + 7), withAttributes: attrs)
    }

    private func convertFromGlobal(_ point: CGPoint) -> CGPoint {
        guard let screen = window?.screen else {
            return point
        }

        // AXUIElement positions are reported in top-left-origin "Quartz" global
        // display coordinates. NSScreen.frame is bottom-left-origin "Cocoa" space.
        // Our content view is flipped (top-left origin), so we must convert
        // Quartz-global -> Cocoa-global -> Cocoa-local-to-screen -> flipped-local,
        // rather than naively subtracting from this screen's maxY (which double-flips
        // and scatters labels far from their real on-screen position).
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let localX = point.x - screen.frame.minX
        let cocoaGlobalY = primaryHeight - point.y
        let localCocoaY = cocoaGlobalY - screen.frame.minY
        let localY = screen.frame.height - localCocoaY
        return CGPoint(x: localX, y: localY)
    }
}
