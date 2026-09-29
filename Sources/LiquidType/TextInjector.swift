import AppKit
import Carbon

/// 把文本写进当前前台 app。
/// - type：按 Unicode 键盘事件逐段打字（不碰剪贴板，流式逐句输入用这个；flags 显式清空，
///   用户此刻还按着说话键也不会变成 ⌥+字符）
/// - paste：保存剪贴板 → 写入 → ⌘V → 延迟恢复（大段文字兜底）
enum TextInjector {
    static func type(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let utf16 = Array(text.utf16)
        // The events pass through the current input method first: note which one, for when text goes missing
        Log.write("Type: \(utf16.count) units in \((utf16.count + 19) / 20) events, input source \(currentInputSource())")
        var i = 0
        while i < utf16.count {
            let end = min(i + 20, utf16.count) // 单个事件最多约 20 个 UTF-16 单元
            var chunk = Array(utf16[i..<end])
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            down?.flags = []
            up?.flags = []
            down?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            up?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
            i = end
            usleep(2_000)
        }
    }

    private static func currentInputSource() -> String {
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { return "?" }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    /// `keep`: leave the text on the clipboard afterwards instead of putting back what was there
    static func paste(_ text: String, restoreDelayMs: UInt32 = 350, keep: Bool = false) {
        let pasteboard = NSPasteboard.general
        let saved: [NSPasteboardItem] = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true) // kVK_ANSI_V
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        if keep { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(Int(restoreDelayMs))) {
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
    }

    static func copyOnly(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// What has the keyboard focus in an app, as far as Accessibility can tell
    enum Focus: Equatable {
        case text               // a text field or text area: type into it
        case other(String)      // clearly something else (a toolbar, a web page, a list): typing would go nowhere
        case unknown(String)    // nothing readable (WeChat draws its own), or only a window or group around it; what was read
    }

    private static let textRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole]
    /// Too vague to tell: an app that exposes no more than these may well be drawing its own text box inside.
    /// A group is not among them: Claude reports one with the focus off its text box (2026-09-30), and a
    /// wrong guess there only costs a ⌘V
    private static let vagueRoles: Set<String> = [kAXWindowRole, kAXApplicationRole, kAXLayoutAreaRole, kAXUnknownRole]

    static func focus(in app: NSRunningApplication?) -> Focus {
        guard let app else { return .unknown("no app") }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appEl, 0.2)
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &value)
        guard err == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return .unknown("error \(err.rawValue)") }
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(value as! AXUIElement, kAXRoleAttribute as CFString, &role) == .success,
              let role = role as? String else { return .unknown("no role") }
        if textRoles.contains(role) { return .text }
        return vagueRoles.contains(role) ? .unknown(role) : .other(role)
    }
}
