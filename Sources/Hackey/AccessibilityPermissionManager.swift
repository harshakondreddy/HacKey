import ApplicationServices
import Foundation

@MainActor
final class AccessibilityPermissionManager {
    func ensurePermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    var isTrusted: Bool {
        AXIsProcessTrusted()
    }
}
