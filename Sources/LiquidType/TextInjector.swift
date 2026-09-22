import AppKit

/// 把文本写进当前前台 app。
/// - type：按 Unicode 键盘事件逐段打字（不碰剪贴板，流式逐句输入用这个；flags 显式清空，
///   用户此刻还按着说话键也不会变成 ⌥+字符）
/// - paste：保存剪贴板 → 写入 → ⌘V → 延迟恢复（大段文字兜底）
enum TextInjector {
    static func type(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let utf16 = Array(text.utf16)
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

    static func paste(_ text: String, restoreDelayMs: UInt32 = 350) {
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

        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(Int(restoreDelayMs))) {
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
    }

    static func copyOnly(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
