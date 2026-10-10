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
    /// Text copied while dictating (see Clip). The transcript holds their placeholders
    private(set) var clips: [Clip] = []
    /// Copied while a sentence was still being heard: the placeholder goes into that sentence once it's final
    private var waiting: [(token: String, offset: Int)] = []
    private var broughtBack = false

    init(target: NSRunningApplication?, style: AppStyle, appName: String?, polish: Bool, usePaste: Bool) {
        self.target = target
        self.style = style
        self.appName = appName
        self.polish = polish
        self.usePaste = usePaste
    }

    var pendingRaw: String { rawSentences.joined() }
    var rawText: String { rawSentences.joined() }
    /// The pill's view: each placeholder as its clip's label, the waiting ones inside the sentence being heard
    var pendingShown: String { Clip.labeled(pendingRaw, with: clips) }
    func partialShown(_ partial: String) -> String { Clip.labeled(Clip.insert(waiting, into: partial), with: clips) }

    func addSentence(_ raw: String) {
        guard !aborted else { return }
        rawSentences.append(Clip.insert(waiting, into: raw))
        waiting = []
        onProgress?(written, pendingShown)
    }

    /// Copied while dictating, with `partial` heard of the current sentence so far. In a pause (the usual case:
    /// talking stops while you go and copy) it goes between sentences
    func addClip(_ text: String, partial: String) {
        guard !aborted, text != clips.last?.text else { return }
        let clip = Clip(text: text, number: clips.count + 1)
        clips.append(clip)
        if partial.isEmpty { rawSentences.append(clip.token) } else { waiting.append((clip.token, partial.count)) }
        Log.write("Clip \(clip.token): \(text.count) chars, \(partial.count) into the sentence being heard")
        onProgress?(written, pendingShown)
    }

    /// 松键、尾句已补齐：整段润色一次，再写入
    func finishInput() {
        guard !aborted else { return }
        let raw = rawSentences.joined()
        guard !raw.isEmpty else { onDone?(""); return }
        if polish {
            // Jev fast path (beta), a race: whichever settles first wins. A confident Jev "clean" types the raw
            // text right away; anything else waits for polish, so the worst case is today's latency.
            // A losing polish still runs to completion and is logged, for recalibrating the threshold.
            var settled = false
            let t0 = Date()
            // Placeholders are for the cleanup model to place, so a dictation with clips always goes through it
            if JevGate.enabled && style.fastPath && clips.isEmpty {
                let threshold = Config.shared.jevThreshold
                JevGate.check(raw) { [weak self] score in
                    let ms = Int(Date().timeIntervalSince(t0) * 1000)
                    guard let score else { return }
                    guard !settled else { Log.write("Jev \(score) in \(ms)ms, after polish"); return }
                    guard score >= threshold else { Log.write("Jev \(score) in \(ms)ms → polish"); return }
                    Log.write("Jev \(score) in \(ms)ms → skip polish")
                    settled = true
                    guard let self, !self.aborted else { return }
                    self.inject(raw)
                }
            }
            Polisher.polish(raw, style: style, appName: appName) { [weak self] text, _ in
                guard !settled else { Log.write("Polish discarded [\(text)]"); return }
                settled = true
                guard let self, !self.aborted else { return }
                self.inject(text)
            }
        } else {
            inject(raw)
        }
    }

    func abort() { aborted = true }

    private func inject(_ text: String) {
        deliver(Clip.fill(text, with: clips))
    }

    private func deliver(_ text: String) {
        if let target, let front = NSWorkspace.shared.frontmostApplication,
           target.processIdentifier != front.processIdentifier {
            // Still off in another app where something was copied for this dictation: go back to the app it
            // started in, which keeps its own focus, and type there
            if !clips.isEmpty && !broughtBack {
                broughtBack = true
                Log.write("Back to \(target.localizedName ?? "?") from \(front.localizedName ?? "?") to type the clips in")
                let app = AXUIElementCreateApplication(target.processIdentifier)
                AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self, !self.aborted else { return }
                    self.deliver(text)
                }
                return
            }
            aborted = true
            onAbort?(HUDCopy.switchedApps, text)
            return
        }
        // Where the keyboard focus is decides how the text goes in, the same rule in every app:
        // - a text box: type it
        // - clearly not a text box (Claude with the focus off its text box, a web page): typing would go nowhere
        //   or set off shortcuts, so copy it and say "press ⌘V"
        // - can't be told (WeChat draws its own; Claude's second conversation reports no focus at all): paste it
        //   and leave it on the clipboard. A paste lands whole or not at all, where keystrokes an app catches
        //   itself can come out as a few stray characters, even in another conversation's text box
        switch TextInjector.focus(in: target) {
        case .other(let role):
            Log.write("Focus: \(role), not a text box: copied instead of typing")
            aborted = true
            onAbort?(HUDCopy.cantType, text)
            return
        case .unknown(let what):
            Log.write("Focus: can't tell (\(what)), pasting and leaving it on the clipboard")
            TextInjector.paste(text, keep: true)
        case .text:
            // 多行文本一律走 ⌘V：逐字打字时换行会变成回车，在聊天类输入框里等于直接发送
            if usePaste || text.contains("\n") { TextInjector.paste(text) } else { TextInjector.type(text) }
        }
        written = text
        onProgress?(written, "")
        onDone?(written)
    }
}
