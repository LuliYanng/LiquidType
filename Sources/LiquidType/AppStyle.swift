import AppKit

/// 按前台 app 决定润色风格。HUD 上显示 app 图标 + 风格名，让用户一眼知道
/// "我在哪儿输入、她会按什么口吻整理"。
struct AppStyle {
    let label: String   // HUD 上的短标签
    let hint: String    // 喂给润色模型的风格说明
    var blankLines = false   // 允许段落之间空一行（邮件）；其他场景后处理会把空行压掉

    static let generic = AppStyle(label: "通用", hint: "普通输入框：保持用户原本的口语说法，只做整理。")

    private static let table: [(match: [String], style: AppStyle)] = [
        (["com.tencent.xinwechat", "com.tencent.qq", "com.tencent.wework"],
         AppStyle(label: "聊天", hint: "这是微信这类聊天软件里的消息：口语自然，保留用户的说法和语气，只去纯粹的口头禅；讲到不同的事可以换行，但不要空行；句尾不加句号。")),
        (["com.tinyspeck.slackmacgap", "com.electron.lark", "com.bytedance.lark", "com.alibaba.dingtalkmac", "ru.keepcoder.telegram", "com.hnc.discord", "net.whatsapp.whatsapp", "com.apple.messages"],
         AppStyle(label: "即时消息", hint: "这是即时通讯消息：保持口语，讲到不同的事可以换行，但不要空行，句尾不加句号。")),
        (["com.apple.mail", "com.microsoft.outlook", "com.readdle.smartemail", "com.superhuman", "com.google.gmail"],
         AppStyle(label: "邮件", hint: "这是邮件正文：这是唯一允许适度书面化的场景——完整句子、礼貌，按邮件格式排版：称呼单独一行，然后空一行；正文按意思分段，段落之间空一行；列举用编号；结尾问候前空一行，问候和署名各单独一行。", blankLines: true)),
        (["com.apple.terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.warp"],
         AppStyle(label: "终端", hint: "这是命令行终端：命令、路径、参数、英文术语一律原样保留，不要给命令加中文标点，不要翻译英文。")),
        (["com.todesktop.230313mzl4w4u92", "com.microsoft.vscode", "com.apple.dt.xcode", "com.jetbrains", "com.sublimetext", "dev.zed.zed", "com.exafunction.windsurf"],
         AppStyle(label: "代码", hint: "这是代码编辑器：技术术语、变量名、文件名、英文原样保留，表达简洁准确。")),
        (["com.anthropic.claudefordesktop", "com.openai.chat", "com.google.gemini", "ai.perplexity"],
         AppStyle(label: "AI 对话", hint: "用户正在给另一个 AI 助手（不是你）写消息，你只整理、不回应：保持用户的口语原样，保留所有细节、例子和意图，不精简、不改写成指令体；有多个要求或步骤时分行编号。")),
        (["com.apple.notes", "md.obsidian", "notion.id", "com.lukilabs.lukiapp", "com.apple.textedit", "com.flexibits", "abnerworks.typora", "com.bear-writer"],
         AppStyle(label: "笔记", hint: "这是笔记：可以稍微书面一点、条理清楚，但用词还是用户自己的。")),
        (["com.google.chrome", "com.apple.safari", "company.thebrowser", "org.mozilla.firefox", "com.microsoft.edgemac", "com.brave.browser"],
         AppStyle(label: "网页", hint: "这是网页里的输入框：保持用户原本的口语说法，只做整理。")),
    ]

    /// 按 HUD 标签取样式（--test-polish 用）
    static func named(_ label: String) -> AppStyle? { table.first { $0.style.label == label }?.style }

    static func forApp(_ app: NSRunningApplication?) -> AppStyle {
        guard let id = app?.bundleIdentifier?.lowercased() else { return generic }
        for row in table where row.match.contains(where: { id.hasPrefix($0) }) { return row.style }
        return generic
    }
}
