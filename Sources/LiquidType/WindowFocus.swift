import AppKit

/// 平时是 accessory（没有 Dock 图标），这种 app 从 macOS 14 起 `NSApp.activate` 基本失效——
/// 窗口会开在别人后面、键盘还留在原来那个 app 里。要开真窗口时临时切成 regular，全关了再切回去。
/// （菜单栏面板不走这条路：它是 nonactivating panel，不激活 app 也能拿键盘。）
enum WindowFocus {
    private static var open = 0

    static func begin() {
        open += 1
        NSApp.setActivationPolicy(.regular)
    }

    static func end() {
        open = max(0, open - 1)
        if open == 0 { NSApp.setActivationPolicy(.accessory) }
    }
}
