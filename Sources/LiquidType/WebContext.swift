import AppKit
import ApplicationServices

/// 浏览器里干活的场景：拿到当前标签页 URL，按站点决定风格 + 图标。
/// URL 走 AX 属性 AXDocument：Chrome/Safari 把当前页 URL 放在焦点窗口的 AXDocument 上，
/// 用的是已有的辅助功能权限，零额外弹窗，实测 36ms。曾加过 AppleScript 兜底，实测浏览器
/// 没开窗口时它会卡 4.6s 才报错（按键响应不能有这种尾巴），去掉了。
struct WebSite {
    let hosts: [String]      // host 后缀匹配
    let label: String
    let style: AppStyle
    let icon: String         // Resources/WebIcons/<icon>.png
}

enum WebContext {
    static let browsers: Set<String> = [
        "com.google.chrome", "com.google.chrome.canary", "com.apple.safari", "company.thebrowser.browser",
        "org.mozilla.firefox", "com.microsoft.edgemac", "com.brave.browser", "org.chromium.chromium",
        "com.vivaldi.vivaldi", "company.thebrowser.dia", "com.openai.atlas",
    ]

    private static let chat = AppStyle(label: "即时消息", hint: "这是即时通讯消息：保持口语，讲到不同的事可以换行，但不要空行，句尾不加句号。")
    private static let mail = AppStyle(label: "邮件", hint: "这是邮件正文：这是唯一允许适度书面化的场景——完整句子、礼貌，按邮件格式排版：称呼单独一行，然后空一行；正文按意思分段，段落之间空一行；列举用编号；结尾问候前空一行，问候和署名各单独一行。", blankLines: true)
    private static let ai = AppStyle(label: "AI 对话", hint: "这是对 AI 助手说的话：保持用户的口语原样，保留所有细节、例子和意图，不精简、不改写成指令体；有多个要求或步骤时分行编号。")
    private static let notes = AppStyle(label: "文档", hint: "这是在线文档/笔记：可以稍微书面一点、条理清楚，但用词还是用户自己的。")
    private static let code = AppStyle(label: "代码", hint: "这是代码托管/工程协作平台：技术术语、变量名、文件名、英文原样保留，表达简洁准确。")
    private static let social = AppStyle(label: "社交", hint: "这是社交平台的帖子或评论：保持口语和个人语气，不要书面化，可以换行但不要空行。")

    static let sites: [WebSite] = [
        WebSite(hosts: ["mail.google.com"], label: "Gmail", style: mail, icon: "gmail"),
        WebSite(hosts: ["outlook.live.com", "outlook.office.com", "outlook.office365.com"], label: "Outlook", style: mail, icon: "outlook"),
        WebSite(hosts: ["slack.com"], label: "Slack", style: chat, icon: "slack"),
        WebSite(hosts: ["web.telegram.org"], label: "Telegram", style: chat, icon: "telegram"),
        WebSite(hosts: ["discord.com"], label: "Discord", style: chat, icon: "discord"),
        WebSite(hosts: ["web.whatsapp.com"], label: "WhatsApp", style: chat, icon: "whatsapp"),
        WebSite(hosts: ["claude.ai"], label: "Claude", style: ai, icon: "claude"),
        WebSite(hosts: ["chatgpt.com", "chat.openai.com"], label: "ChatGPT", style: ai, icon: "chatgpt"),
        WebSite(hosts: ["gemini.google.com"], label: "Gemini", style: ai, icon: "gemini"),
        WebSite(hosts: ["perplexity.ai"], label: "Perplexity", style: ai, icon: "perplexity"),
        WebSite(hosts: ["chat.deepseek.com"], label: "DeepSeek", style: ai, icon: "deepseek"),
        WebSite(hosts: ["kimi.moonshot.cn", "kimi.com"], label: "Kimi", style: ai, icon: "kimi"),
        WebSite(hosts: ["doubao.com"], label: "豆包", style: ai, icon: "doubao"),
        WebSite(hosts: ["notion.so", "notion.site"], label: "Notion", style: notes, icon: "notion"),
        WebSite(hosts: ["docs.google.com"], label: "Google Docs", style: notes, icon: "gdocs"),
        WebSite(hosts: ["feishu.cn", "larksuite.com"], label: "飞书", style: notes, icon: "feishu"),
        WebSite(hosts: ["yuque.com"], label: "语雀", style: notes, icon: "yuque"),
        WebSite(hosts: ["github.com"], label: "GitHub", style: code, icon: "github"),
        WebSite(hosts: ["gitlab.com"], label: "GitLab", style: code, icon: "gitlab"),
        WebSite(hosts: ["linear.app"], label: "Linear", style: notes, icon: "linear"),
        WebSite(hosts: ["atlassian.net"], label: "Jira", style: notes, icon: "jira"),
        WebSite(hosts: ["x.com", "twitter.com"], label: "X", style: social, icon: "x"),
        WebSite(hosts: ["weibo.com"], label: "微博", style: social, icon: "weibo"),
        WebSite(hosts: ["xiaohongshu.com"], label: "小红书", style: social, icon: "xiaohongshu"),
    ]

    struct Match {
        let site: WebSite
        let url: String
        /// 站点 favicon 规范化成 app 图标的观感：favicon 是满幅方块，而 macOS app 图标自带约 10% 透明边距、
        /// 大圆角，直接并排会显得又大又方。这里统一画到 64pt 画布：内容缩到 80%、居中、22% 圆角裁切。
        var icon: NSImage? {
            guard let u = Bundle.module.url(forResource: site.icon, withExtension: "png", subdirectory: "WebIcons"),
                  let src = NSImage(contentsOf: u) else { return nil }
            let canvas: CGFloat = 64
            let inset: CGFloat = canvas * 0.10
            let side = canvas - inset * 2
            let img = NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { _ in
                let rect = NSRect(x: inset, y: inset, width: side, height: side)
                NSBezierPath(roundedRect: rect, xRadius: side * 0.22, yRadius: side * 0.22).addClip()
                src.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
                return true
            }
            return img
        }
    }

    static func isBrowser(_ app: NSRunningApplication?) -> Bool {
        guard let id = app?.bundleIdentifier?.lowercased() else { return false }
        return browsers.contains(id)
    }

    /// 前台是浏览器时取当前标签页 URL 并匹配站点；不是浏览器或拿不到返回 nil。主线程调用。
    static func detect(_ app: NSRunningApplication?) -> Match? {
        guard let app, isBrowser(app) else { return nil }
        let t0 = Date()
        let url = axDocumentURL(pid: app.processIdentifier)
        let via = "AX"
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        guard let url, let host = URL(string: url)?.host?.lowercased() else {
            Log.write("Web URL: none (\(ms)ms)")
            return nil
        }
        let site = sites.first { $0.hosts.contains { h in host == h || host.hasSuffix("." + h) } }
        Log.write("Web URL via \(via) in \(ms)ms: \(host) → \(site?.label ?? "未知站点")")
        guard let site else { return nil }
        return Match(site: site, url: url)
    }

    private static func axDocumentURL(pid: pid_t) -> String? {
        let appEl = AXUIElementCreateApplication(pid)
        var win: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &win) == .success,
              let winEl = win else { return nil }
        var doc: CFTypeRef?
        guard AXUIElementCopyAttributeValue(winEl as! AXUIElement, kAXDocumentAttribute as CFString, &doc) == .success,
              let s = doc as? String, s.hasPrefix("http") else { return nil }
        return s
    }

}
