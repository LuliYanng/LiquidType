import AppKit

/// 一次按住说话的账本：说话期间只攒句子给浮窗显示，**不碰输入框**；
/// 松键后整段送一次 LLM 润色，完成后一次性写入前台 app。
final class StreamSession {
    let target: NSRunningApplication?
    let style: AppStyle
    let appName: String?
    let polish: Bool
    let usePaste: Bool

    /// (已写入的文本, 已定稿但还没写入的原文) —— HUD 用
    var onProgress: ((String, String) -> Void)?
    var onDone: ((String) -> Void)?
    var onAbort: ((String, String) -> Void)?   // (原因, 未写入的文本)

    private var rawSentences: [String] = []
    private var aborted = false
    private(set) var written = ""

    init(target: NSRunningApplication?, style: AppStyle, appName: String?, polish: Bool, usePaste: Bool) {
        self.target = target
        self.style = style
        self.appName = appName
        self.polish = polish
        self.usePaste = usePaste
    }

    var pendingRaw: String { rawSentences.joined() }
    var rawText: String { rawSentences.joined() }

    func addSentence(_ raw: String) {
        guard !aborted else { return }
        rawSentences.append(raw)
        onProgress?(written, pendingRaw)
    }

    /// 松键、尾句已补齐：整段润色一次，再写入
    func finishInput() {
        guard !aborted else { return }
        let raw = rawSentences.joined()
        guard !raw.isEmpty else { onDone?(""); return }
        if polish {
            Polisher.polish(raw, style: style, appName: appName) { [weak self] text, _ in
                guard let self, !self.aborted else { return }
                self.inject(text)
            }
        } else {
            inject(raw)
        }
    }

    func abort() { aborted = true }

    private func inject(_ text: String) {
        if let target, let front = NSWorkspace.shared.frontmostApplication,
           target.processIdentifier != front.processIdentifier {
            aborted = true
            onAbort?(HUDCopy.switchedApps, text)
            return
        }
        // 多行文本一律走 ⌘V：逐字打字时换行会变成回车，在聊天类输入框里等于直接发送
        if usePaste || text.contains("\n") { TextInjector.paste(text) } else { TextInjector.type(text) }
        written = text
        onProgress?(written, "")
        onDone?(written)
    }
}
