import AppKit
import CoreGraphics
import Foundation

/// Deliberately never uses `AXUIElementPerformAction`/`kAXPressAction` (a semantic
/// action on the accessibility element) to perform a click. That action executes
/// directly inside the target app/process and can silently "succeed" while doing
/// something other than what a real physical click at that screen point would do -
/// e.g. toggling a different-but-adjacent AX node (a tree row's disclosure chevron
/// vs. its link), or a duplicate-titled element that isn't the one visually under
/// the badge. Instead this always synthesizes a genuine OS-level mouse click at the
/// exact on-screen point, moving the real cursor there first - the same approach
/// Vimac (a proven, widely-used hint-mode tool) uses exclusively. This guarantees
/// the click behaves exactly like a human physically clicking that pixel, which is
/// unambiguous and independent of the app's internal AX action wiring.
final class InteractionPerformer {
    func moveMouse(to point: CGPoint) {
        let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
        move?.post(tap: .cghidEventTap)
    }

    func leftClick(at point: CGPoint) {
        moveMouse(to: point)
        mouseClick(at: point, button: .left)
    }

    func rightClick(at point: CGPoint) {
        moveMouse(to: point)
        mouseClick(at: point, button: .right)
    }

    func doubleLeftClick(at point: CGPoint) {
        // A real double-click is TWO separate click events where the OS tracks an
        // incrementing click count: the first click is state 1, the second is state 2.
        // Stamping both pairs as state 2 (as if every click were already "the second
        // click") is not a valid double-click sequence and many apps (Finder's
        // icon-grid included) silently ignore it - the icon gets selected/highlighted
        // by the first pair but never actually opens.
        moveMouse(to: point)
        mouseClick(at: point, button: .left, clickCount: 1)
        mouseClick(at: point, button: .left, clickCount: 2)
    }

    func commandClick(at point: CGPoint) {
        moveMouse(to: point)
        mouseClick(at: point, button: .left, flags: .maskCommand)
    }

    func scroll(deltaX: Int32, deltaY: Int32) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: deltaY, wheel2: deltaX, wheel3: 0) else {
            return
        }
        event.post(tap: .cghidEventTap)
    }

    private func mouseClick(at point: CGPoint, button: CGMouseButton, clickCount: Int64 = 1, flags: CGEventFlags = []) {
        let downType: CGEventType = button == .left ? .leftMouseDown : .rightMouseDown
        let upType: CGEventType = button == .left ? .leftMouseUp : .rightMouseUp

        guard let down = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: point, mouseButton: button),
              let up = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: point, mouseButton: button) else {
            return
        }

        down.flags = flags
        up.flags = flags
        down.setIntegerValueField(.mouseEventClickState, value: clickCount)
        up.setIntegerValueField(.mouseEventClickState, value: clickCount)

        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
