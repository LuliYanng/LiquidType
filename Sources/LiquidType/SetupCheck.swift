import AppKit
import AVFoundation

/// 装完能不能用，就看这三样。缺哪样，菜单顶上就多一行，点了直达对应的系统设置。
enum SetupCheck {
    static var accessibility: Bool { HotkeyMonitor.ensureAccessibilityPermission(prompt: false) }

    static var microphone: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    /// 系统设置 → 键盘 →「按下 fn 键时」。0 = 不执行任何操作，正是我们要的；
    /// 没设过（nil）也算没就绪——系统默认会拿 fn 去切输入法或开表情面板，会跟说话键打架
    static var fnUsage: Int? {
        UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int
    }

    /// 说话键不是 fn 就不用管系统拿 fn 干什么
    static var fnReady: Bool { Config.shared.hotkey != .fn || fnUsage == 0 }

    /// fn 现在被系统拿去干什么了
    static var fnDoing: String {
        switch fnUsage {
        case 1: return "Change Input Source"
        case 2: return "Show Emoji & Symbols"
        case 3: return "Start Dictation"
        default: return "not set to Do Nothing"
        }
    }

    static let accessibilityPane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    static let microphonePane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    static let keyboardPane = "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"

    /// 还差的那几样：菜单上的一行字 + 要打开的系统设置页
    static var missing: [(title: String, pane: String)] {
        var out: [(String, String)] = []
        if !accessibility {
            out.append(("⚠ Grant Accessibility, then relaunch…", accessibilityPane))
        }
        if !microphone {
            out.append(("⚠ Grant Microphone access…", microphonePane))
        }
        if !fnReady {
            out.append(("⚠ fn is set to “\(fnDoing)” — set it to Do Nothing…", keyboardPane))
        }
        return out
    }
}
