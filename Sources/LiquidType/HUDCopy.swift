import Foundation

/// 胶囊上会出现的提示 / 报错，全在这儿。写法：发生了什么 + 逗号 + 该怎么办，第一人称，
/// 按默认字号量过都放得进胶囊的最宽宽度（HUD.maxPillWidth）——加新的或者改长了记得用 --preview-hud --messages 看一眼。
enum HUDCopy {
    static var noSpeech: String { "Didn't hear anything" }
    static var micDenied: String { "Can't hear you, allow Microphone in Settings" }
    static var accessibilityNeeded: String { "Grant Accessibility access, then relaunch me" }
    /// 具体缺哪家的 key 面板里看得到
    static var noAPIKey: String { "No API key yet, add one from the menu bar" }
    static var micUnreachable: String { "Can't reach the mic, try relaunching me" }
    static var micSilent: String { "The mic's gone quiet, try relaunching me" }
    /// 技术原因 ASR 自己写进日志，胶囊上只说人话
    static var connectionLost: String { "Lost the connection, please try again" }
    static var cantType: String { "Can't type here, press ⌘V to paste" }
    static var switchedApps: String { "You switched apps, press ⌘V to paste" }

    static var all: [String] {
        [noSpeech, micDenied, accessibilityNeeded, noAPIKey, micUnreachable, micSilent, connectionLost, cantType, switchedApps]
    }
}
