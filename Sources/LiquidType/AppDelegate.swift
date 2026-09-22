import AppKit

/// 状态机：idle → listening（按住）→ finishing（等尾句 + 写完队列）→ idle
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum State { case idle, listening, finishing }

    private var state: State = .idle
    private var statusItem: NSStatusItem!
    private var hotkey: HotkeyMonitor!
    private let audio = AudioCapture()
    private let hud = HUD()
    private var asr: ASREngine?
    private var session: StreamSession?
    private var partial = ""
    private var pressedAt = Date()
    private var releasedAt = Date()
    private let menuPanel = MenuPanelController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("LiquidType launched (log: \(Log.path))")
        setupStatusItem()
        AudioCapture.requestPermission { ok in
            Log.write("Mic permission: \(ok)")
            if !ok { self.flash(.error, HUDCopy.micDenied, 4) }
        }
        let trusted = HotkeyMonitor.ensureAccessibilityPermission(prompt: true)
        Log.write("Accessibility trusted: \(trusted)")
        if !trusted {
            flash(.error, HUDCopy.accessibilityNeeded, 6)
        }
        // 一把 key 都没有就什么也干不了：第一屏直接把面板摆出来（缺的那把 key 会自己摊开），别让人猜
        if ASRModel.find(Config.shared.asrChoice).keyMissing {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.togglePanel() }
        }

        hotkey = HotkeyMonitor(choice: Config.shared.hotkey)
        hotkey.onDown = { [weak self] in self?.beginListening() }
        hotkey.onConfirm = { [weak self] in self?.confirmListening() }
        hotkey.onCancel = { [weak self] in self?.cancel(reason: "tap/chord") }
        hotkey.onUp = { [weak self] in self?.endListening() }
        hotkey.onEscape = { [weak self] in
            guard let self, self.state == .listening else { return }
            self.cancel(reason: "esc")
        }
        hotkey.isListening = { [weak self] in self?.state == .listening }
        hotkey.toggleMode = Config.shared.toggleMode
        hotkey.onToggle = { [weak self] in
            guard let self else { return }
            switch self.state {
            case .idle: self.beginListening(); self.confirmListening()
            case .listening: self.endListening()
            case .finishing: break
            }
        }
        hotkey.start()
        Polisher.startKeepWarm()
    }

    /// 退出时兜底：别把用户的外放留在静音状态
    func applicationWillTerminate(_ notification: Notification) {
        SystemAudio.restore()
    }

    private func flash(_ mode: HUD.Mode, _ message: String, _ seconds: TimeInterval) {
        hud.show(mode, message: message)
        hud.hide(after: seconds)
    }

    // MARK: - 菜单栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setIcon(listening: false)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)

        let m = menuPanel.model
        m.slots = keySlots
        m.onOpenLog = { [weak self] in self?.menuPanel.close(); self?.openLog() }
    }

    /// 面板里的 key 清单
    private var keySlots: [KeySlot] {
        let cfg = Config.shared
        return [
            KeySlot(id: 0, title: "DashScope", purpose: "Qwen ASR Flash · Qwen3.7-Flash. This one alone is enough", placeholder: "sk-…",
                    get: { cfg.apiKey }, set: { cfg.apiKey = $0 },
                    needed: { cfg.asrChoice != "cartesia" || !PolishModel.isOpenRouter(cfg.polishModel) }),
            KeySlot(id: 1, title: "OpenRouter", purpose: "Claude Haiku 4.5", placeholder: "sk-or-…",
                    get: { cfg.openrouterKey }, set: { cfg.openrouterKey = $0; Polisher.startKeepWarm() },
                    needed: { PolishModel.isOpenRouter(cfg.polishModel) }),
            KeySlot(id: 2, title: "Cartesia", purpose: "English speech, ink-2", placeholder: "sk_car_…",
                    get: { cfg.cartesiaKey }, set: { cfg.cartesiaKey = $0 },
                    needed: { cfg.asrChoice == "cartesia" }),
        ]
    }

    /// 按住 ⌥ 点图标：面板底下多出打开日志
    @objc private func togglePanel() {
        menuPanel.model.devMode = NSEvent.modifierFlags.contains(.option)
        menuPanel.toggle(under: statusItem.button)
    }

    private func setIcon(listening: Bool) {
        let img = NSImage(systemSymbolName: listening ? "mic.fill" : "mic", accessibilityDescription: "LiquidType")
        img?.isTemplate = true
        statusItem.button?.image = img
        statusItem.button?.contentTintColor = listening ? .controlAccentColor : nil
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: Log.path))
    }

    // MARK: - 会话

    private func beginListening() {
        guard state == .idle else { return }
        let model = ASRModel.find(Config.shared.asrChoice)
        guard let client = ASRModel.makeEngine(model) else {
            flash(.error, HUDCopy.noAPIKey, 3)
            return
        }
        state = .listening
        pressedAt = Date()
        partial = ""
        if Config.shared.polishEnabled { Polisher.warm() }
        let cfg = Config.shared
        let target = NSWorkspace.shared.frontmostApplication
        var style = AppStyle.forApp(target)
        var icon: NSImage? = nil
        var appName = target?.localizedName
        if let web = WebContext.detect(target) {
            style = web.site.style
            icon = web.icon
            appName = web.site.label
        }
        hud.setContext(app: target, style: style, icon: icon)

        let sess = StreamSession(target: target, style: style, appName: appName, polish: cfg.polishEnabled, usePaste: cfg.usePaste)
        sess.onProgress = { [weak self, weak sess] written, pending in
            guard let self, self.session === sess, self.state != .idle else { return }
            self.hud.show(self.state == .listening ? .listening : .thinking, written: written, pending: pending, partial: self.partial)
        }
        sess.onDone = { [weak self, weak sess] written in
            guard let self, self.session === sess else { return }
            self.finishSession(written: written)
        }
        sess.onAbort = { [weak self, weak sess] reason, rest in
            guard let self, self.session === sess else { return }
            Log.write("Abort: \(reason) rest=[\(rest)]")
            TextInjector.copyOnly(rest)
            self.teardown()
            self.flash(.error, reason, 4)
        }
        session = sess

        client.onPartial = { [weak self, weak client] text in
            guard let self, self.asr === client, self.state == .listening, let s = self.session else { return }
            self.partial = text
            self.hud.show(.listening, written: s.written, pending: s.pendingRaw, partial: text)
        }
        client.onSentence = { [weak self, weak client] text in
            guard let self, self.asr === client, self.state != .idle else { return }
            Log.write("Sentence [\(text)]")
            self.partial = ""
            self.session?.addSentence(text)
        }
        client.onError = { [weak self, weak client] _ in   // 技术原因 ASR 自己已经写进日志，胶囊上只说人话
            guard let self, self.asr === client else { return }
            self.flash(.error, HUDCopy.connectionLost, 3)
        }
        asr = client
        client.connect()
        // 先掐掉外放再开麦：正在放的视频/音乐不会被自己的麦克风收回去
        if cfg.muteWhileListening { SystemAudio.muteIfPlaying() }
        audio.start(
            onLevel: { [weak self, weak client] rms in
                guard let self, self.asr === client, self.state == .listening else { return }
                self.hud.setLevel(rms: rms)
            },
            onChunk: { [weak client] chunk in client?.send(chunk) },
            // 麦克风没起来就别让人干等着说完再看到"没听到内容"
            onError: { [weak self, weak client] msg in
                guard let self, self.asr === client else { return }
                self.cancel(reason: "mic")
                self.flash(.error, msg, 4)
            }
        )
        Log.write("Listening → \(target?.localizedName ?? "?") [\(target?.bundleIdentifier ?? "")] style=\(style.label) asr=\(model.id)")
    }

    private func confirmListening() {
        guard state == .listening else { return }
        setIcon(listening: true)
        hud.show(.listening)
    }

    private func cancel(reason: String) {
        guard state == .listening else { return }
        Log.write("Cancel (\(reason)) written=[\(session?.written ?? "")]")
        teardown()
        hud.hide()
    }

    private func endListening() {
        guard state == .listening, let client = asr, let sess = session else { return }
        state = .finishing
        releasedAt = Date()
        audio.stop()
        SystemAudio.restore()
        // 到现在一个字都没识别出来的话先不动：多半是「没听到内容」，别中间硬插一下「思考中」。
        // 尾巴里真等到字了，下面 finish 回调里会再切过去
        if !(sess.written + sess.pendingRaw + partial).isEmpty {
            hud.show(.thinking, written: sess.written, pending: sess.pendingRaw, partial: partial)
        }
        let held = Date().timeIntervalSince(pressedAt)
        client.finish(timeout: 3.0) { [weak self] raw in
            guard let self, self.asr === client else { return }
            self.asr = nil
            self.partial = ""
            let asrTail = Int(Date().timeIntervalSince(self.releasedAt) * 1000)
            Log.write("Held \(Int(held * 1000))ms, ASR tail \(asrTail)ms after release → raw [\(raw)]")
            guard !raw.isEmpty else {
                self.teardown()
                self.flash(.info, HUDCopy.noSpeech, 1.2)
                return
            }
            guard HotkeyMonitor.ensureAccessibilityPermission(prompt: false) else {
                TextInjector.copyOnly(raw)
                self.teardown()
                self.flash(.error, HUDCopy.cantType, 4)
                return
            }
            self.hud.show(.thinking, pending: raw)
            sess.finishInput()
        }
    }

    private func finishSession(written: String) {
        Log.write("Done \(Int(Date().timeIntervalSince(releasedAt) * 1000))ms after release [\(written)]")
        teardown()
        // 字已经落进 app 里了，胶囊不再重复一遍，直接从「思考中」淡出
        hud.hide()
    }

    private func teardown() {
        state = .idle
        audio.stop()
        SystemAudio.restore()
        asr?.cancel()
        asr = nil
        session?.abort()
        session = nil
        setIcon(listening: false)
    }
}
