import AppKit

/// Chromium and Electron apps only build their accessibility tree for assistive apps. Without it the
/// keyboard focus can't be read (to tell a text box from the rest before typing), nor the text (to learn
/// from the user's edits). Electron takes AXManualAccessibility; Chrome itself doesn't, and needs
/// AXEnhancedUserInterface, the switch screen readers flip (it reports an error but works: the focused field
/// showed up about 3 s later, 2026-09-26). That one puts the whole browser in assistive mode, so it's only
/// used on Chromium browsers. Other apps just return an error, which is fine.
///
/// Turned on for the app a dictation starts in, whether learning is on or not, and back off on quitting
final class AssistiveMode {
    static let shared = AssistiveMode()

    /// Apps whose switch was flipped, and which one ("" when it was left alone), to flip back on quitting
    private var flipped: [pid_t: String] = [:]
    /// When that happened, for the log: text going missing right after it would point at assistive mode
    private var since: [pid_t: Date] = [:]

    /// When a dictation into `app` starts: building the tree takes a moment, so asking now means it's
    /// ready by the time the text goes in
    func enable(for app: NSRunningApplication?) {
        guard let app else { return }
        let pid = app.processIdentifier
        guard flipped[pid] == nil else { return }
        flipped[pid] = ""
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.3)
        let name = "\(app.localizedName ?? "?") [\(app.bundleIdentifier ?? "")]"
        // Already on (a screen reader, another tool): leave it, and leave it on when quitting
        if Self.isOn(appEl, "AXManualAccessibility") || Self.isOn(appEl, "AXEnhancedUserInterface") {
            Log.write("Assistive mode already on for \(name)")
            return
        }
        let err = AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if err == .success {
            flipped[pid] = "AXManualAccessibility"
            since[pid] = Date()
            Log.write("AXManualAccessibility on for \(name)")
        } else if WebContext.isBrowser(app), !["com.apple.safari", "org.mozilla.firefox"].contains(app.bundleIdentifier?.lowercased() ?? "") {
            let e = AXUIElementSetAttributeValue(appEl, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            flipped[pid] = "AXEnhancedUserInterface"
            since[pid] = Date()
            Log.write("AXEnhancedUserInterface on for \(name) (returned \(e.rawValue))")
        }
    }

    func since(_ pid: pid_t) -> Date? { since[pid] }

    /// Flip those switches back on quitting: assistive mode costs the app some speed, and
    /// AXEnhancedUserInterface is known to upset window managers moving Chrome's windows
    func restore() {
        for (pid, attribute) in flipped where !attribute.isEmpty {
            let appEl = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appEl, 0.3)
            AXUIElementSetAttributeValue(appEl, attribute as CFString, kCFBooleanFalse)
        }
        let n = flipped.values.filter { !$0.isEmpty }.count
        if n > 0 { Log.write("Switched assistive mode back off in \(n) app(s)") }
        flipped.removeAll()
        since.removeAll()
    }

    private static func isOn(_ appEl: AXUIElement, _ attribute: String) -> Bool {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, attribute as CFString, &v) == .success else { return false }
        return (v as? NSNumber)?.boolValue ?? false
    }
}
