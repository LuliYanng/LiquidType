import AppKit
import Combine
import QuartzCore

/// 屏幕底部一个小胶囊：清透液态玻璃（默认私有变体 19 chromatic），
/// 内容只有前台 app 图标 + 单行跑马灯转写（或者换成几根跟着音量跳的竖条，见 PillContent）。
/// 所有尺寸/材质/投影参数来自 HUDTuning，调参窗口拨动即实时生效。
final class HUD {
    private var panel: NSPanel
    private var spaceObservers: [NSObjectProtocol] = []
    private let container = NSView()          // 透明底座：装投影 + 玻璃
    private let shadowLayer = CALayer()
    private var glass: NSView?                 // GlassPillView（26+）或 NSVisualEffectView
    private let content = NSView()             // 玻璃内容：图标 + 跑马灯
    private let appIcon = NSImageView()
    private let marquee = MarqueeLabel()
    private let wave = WaveformView()
    private let thinking = ThinkingView()
    private enum Showing { case text, wave, thinking }
    private var showing = Showing.text
    private var hideWork: DispatchWorkItem?
    private var pillW: CGFloat = 0             // 胶囊此刻的宽度（变宽 / 收回的动画中间值）
    private var targetW: CGFloat = 0           // 要去的宽度；里面的图标 / 文字按它排，玻璃展开时把它们露出来
    private var widthTween: Timer?
    private static let maxPillWidth: CGFloat = 420
    private var thinkingWord = ""              // 这一次松键抽到的状态词；思考期间会 redraw 好几回，不能每回重抽
    private var hideGen = 0                    // 每次 show / hide 加一：淡出到一半又被叫出来时，旧的收尾就不算数了
    private var sub: AnyCancellable?
    private let margin: CGFloat = 60           // 给投影留的边
    private let tuning = HUDTuning.shared
    private(set) var usesGlass = false
    private(set) var glassVariant: Int? = nil
    private var lastShown: (Mode, String, String, String, String?) = (.info, "", "", "", nil)
    private var peakDB = 0.0                   // 这次说话最近的响度峰值（自动增益用）
    private var peakAt = 0.0
    private var heardDB: [Double] = []         // 这次说话的电平，收尾时记一行日志

    init() {
        panel = Self.makePanel()

        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        shadowLayer.backgroundColor = NSColor.clear.cgColor
        shadowLayer.shadowColor = NSColor.black.cgColor
        container.layer?.addSublayer(shadowLayer)
        panel.contentView = container

        content.wantsLayer = true
        content.layer?.masksToBounds = true    // 胶囊还没展开到位时，按最终宽度排好的文字不能露到玻璃外面
        appIcon.imageScaling = .scaleProportionallyUpOrDown
        content.addSubview(appIcon)
        content.addSubview(marquee)
        content.addSubview(wave)
        content.addSubview(thinking)

        if #available(macOS 26, *) {
            let g = GlassPillView()
            g.contentView = content
            glass = g
            usesGlass = true
        } else {
            let effect = NSVisualEffectView()
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.masksToBounds = true
            effect.addSubview(content)
            glass = effect
        }
        container.addSubview(glass!)
        applyTuning()
        sub = tuning.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.applyTuning(); self?.redraw() }
        }
        watchSpaces()
    }

    deinit {
        let wc = NSWorkspace.shared.notificationCenter
        spaceObservers.forEach { wc.removeObserver($0); NotificationCenter.default.removeObserver($0) }
    }

    /// 别人家 app 全屏时 .statusBar 这一层会被全屏空间盖住，抬到 screenSaver 层，
    /// 配合 canJoinAllSpaces，胶囊才会跟着当前空间走（桌面 / 全屏都照常显示）。
    private static func makePanel() -> NSPanel {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 164),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        p.level = .screenSaver
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false                // 投影自己画，可调
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = overlayBehavior
        return p
    }

    /// 桌面切换 / 别人进出全屏 / 显示器插拔 / 唤醒：这些时刻窗口服务最容易把胶囊钉死在旧空间。
    /// 胶囊正显示着就立刻重登记一次；没显示的话下次 show 时 orderFront 会自查。
    private func watchSpaces() {
        let wc = NSWorkspace.shared.notificationCenter
        let handler: (Notification) -> Void = { [weak self] n in
            guard let self, self.panel.isVisible else { return }
            Log.write("HUD: \(n.name.rawValue) while visible, onActiveSpace=\(self.panel.isOnActiveSpace)")
            self.place(force: false)
            self.orderFront()
        }
        spaceObservers.append(wc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main, using: handler))
        spaceObservers.append(wc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: handler))
        spaceObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main, using: handler))
    }

    /// 最后一招：把内容搬到一个全新的 NSPanel 里。窗口服务对旧窗口的空间归属记录就此作废。
    private func rebuildPanel() {
        let old = panel
        let frame = old.frame
        let ignores = old.ignoresMouseEvents
        old.orderOut(nil)
        old.contentView = nil
        let fresh = Self.makePanel()
        fresh.setFrame(frame, display: false)
        fresh.contentView = container
        fresh.ignoresMouseEvents = ignores
        panel = fresh
        Log.write("HUD: rebuilt panel (old win=\(old.windowNumber))")
    }

    /// 跟着当前空间走、不参与 ⌘` 循环、Exposé 里不缩：别人家 app 全屏时也要露脸。
    /// 不带 .fullScreenAuxiliary——那是给"自己进全屏的 app 的附属窗口"用的，
    /// LiquidType 是 accessory、自己永远不全屏，带上它反而会让胶囊被别人的全屏空间挡掉。
    private static let overlayBehavior: NSWindow.CollectionBehavior =
        [.canJoinAllSpaces, .stationary, .ignoresCycle]

    /// 每次露脸前确认胶囊会落在当前空间。macOS 在"显示器有单独空间"模式下，别人退全屏 / 唤醒 /
    /// 插拔显示器之后，偶尔会把 canJoinAllSpaces 窗口钉死在某一个空间：在那个桌面看不见，
    /// 却出现在另一个桌面上。isOnActiveSpace 能查出这种状态，查出来就逐级处理：
    /// 撤下 → 清空再设回 collectionBehavior（赋同一个值系统当没变）→ 还不行就换一个全新窗口。
    private func orderFront() {
        panel.level = .screenSaver
        let wasVisible = panel.isVisible
        if !panel.isOnActiveSpace {
            Log.write("HUD: panel off active space (visible=\(wasVisible) win=\(panel.windowNumber)), re-registering")
            panel.orderOut(nil)
            panel.collectionBehavior = []
            panel.collectionBehavior = Self.overlayBehavior
            if !panel.isOnActiveSpace {
                rebuildPanel()
                place(force: true)
            }
        }
        panel.orderFrontRegardless()
        if !panel.isOnActiveSpace {
            Log.write("HUD: still off active space after orderFront win=\(panel.windowNumber) frame=\(panel.frame)")
        } else if !wasVisible {
            Log.write("HUD: shown win=\(panel.windowNumber) frame=\(panel.frame) mouse=\(NSEvent.mouseLocation)")
        }
    }

    var debugFrame: NSRect { panel.frame }
    var debugVisible: Bool { panel.isVisible }
    var debugWindowNumber: Int { panel.windowNumber }

    enum Mode { case listening, thinking, error, info }

    private var app: NSRunningApplication?

    func setContext(app: NSRunningApplication?, style: AppStyle, icon: NSImage? = nil) {
        self.app = app
        appIcon.image = icon ?? app?.icon ?? NSImage(systemSymbolName: "text.cursor", accessibilityDescription: nil)
    }

    /// 预览（--preview-hud）：用当前前台 app 的图标 + 示例三层文字
    func showPreview() {
        if app == nil { setContext(app: NSWorkspace.shared.frontmostApplication, style: .generic) }
        show(.listening, written: "然后我在想，是不是这个浮窗可以同时应用液态玻璃的效果？",
             pending: "另外还有一个问题就是其他产品也有这种卖点嘛",
             partial: "但是好像他们并没有显示当前的应用")
        wave.levelSource = { WaveformView.fakeSpeech(CACurrentMediaTime()) }
    }

    func show(_ mode: Mode, written: String = "", pending: String = "", partial: String = "", message: String? = nil) {
        hideWork?.cancel()
        hideGen += 1
        if panel.alphaValue < 1 {              // 正在淡出：从当前透明度直接淡回来，不闪
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.1
                panel.animator().alphaValue = 1
            }
        }
        wave.levelSource = nil
        if mode == .listening, lastShown.0 != .listening {
            peakDB = tuning.barFloor + tuning.barRange
            heardDB.removeAll()
        } else if mode != .listening {
            logHeard()
        }
        if mode == .thinking, lastShown.0 != .thinking || thinkingWord.isEmpty { thinkingWord = Self.pickThinkingWord(not: thinkingWord) }
        lastShown = (mode, written, pending, partial, message)
        redraw()
        place(force: false)
        orderFront()
    }

    /// 麦克风原始 RMS → 柱子高度。门限以下算静音；满格跟着这次说话最近的峰值走（快跟、每秒回落 6 dB）。
    /// 不同麦克风电平差二三十 dB：这台机器自带麦正常说话 p50≈-49、最响≈-37 dBFS（2026-09-20 实测日志），
    /// 所以量程（barRange）默认只留 18 dB——留 25 dB 的话最响的音节也才到七成高，柱子看着像没反应
    func setLevel(rms: Float) {
        guard lastShown.0 == .listening, tuning.content == .waveform else { return }
        let db = 20 * log10(Double(max(rms, 1e-6)))
        let now = CACurrentMediaTime()
        let floor = tuning.barFloor
        // 满格跟着这次说话最近的峰值走，但至少是门限 + barRange：安静时别把底噪放大成一排高柱
        peakDB = max(db, peakDB - 6 * min(0.2, now - peakAt), floor + tuning.barRange)
        peakAt = now
        heardDB.append(db)
        wave.setLevel(CGFloat((db - floor) / (peakDB - floor)))
    }

    /// 一次说话的电平分布写进日志，调「静音门限」时有数可看
    private func logHeard() {
        guard heardDB.count >= 10 else { heardDB.removeAll(); return }
        let s = heardDB.sorted()
        func pct(_ p: Double) -> Int { Int(s[min(s.count - 1, Int(Double(s.count) * p))].rounded()) }
        Log.write("Mic level dBFS: p10=\(pct(0.1)) p50=\(pct(0.5)) p90=\(pct(0.9)) max=\(pct(1)) (floor \(Int(tuning.barFloor)), n=\(s.count))")
        heardDB.removeAll()
    }

    /// 松键后的状态词每次换一个（不跟上一次重样）。没开润色时这一步只是在等识别收尾，就老实说 Thinking
    private static func pickThinkingWord(not last: String) -> String {
        guard Config.shared.polishEnabled else { return "Thinking" }
        let words = ["Thinking", "Polishing", "Tidying up"]
        return words.filter { $0 != last }.randomElement() ?? words[0]
    }

    private func redraw() {
        let (mode, written, pending, partial, message) = lastShown
        let t = tuning
        // 提示 / 报错永远用文字；松开热键之后两种显示都换成「思考中」；只有说话时才有柱子
        // 文字模式刚唤起、还没字的时候是「正在听」，跟「思考中」同一个样式（同一个视图，只换字）
        let waiting = mode == .listening && t.content != .waveform && (written + pending + partial).isEmpty
        let now: Showing = message != nil ? .text : mode == .thinking || waiting ? .thinking
            : t.content == .waveform ? .wave : .text
        if now != showing, panel.isVisible {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.15
            content.layer?.add(fade, forKey: "swap")
        }
        showing = now
        marquee.isHidden = now != .text
        wave.isHidden = now != .wave
        thinking.isHidden = now != .thinking
        if now == .thinking {
            // 「正在听…」只是出字之前的占位，用普通省略号；「思考中」才有跳动的点
            thinking.apply(t, text: waiting ? "Listening" : thinkingWord, hopping: !waiting)
            setWidth(fitting: thinking.contentWidth)
            thinking.start()
            return
        }
        thinking.stop()
        if now == .wave {
            setWidth(fitting: 0)
            wave.apply(t)
            wave.begin()
            return
        }
        let font = NSFont.systemFont(ofSize: t.fontSize, weight: .medium)
        let base: NSColor = t.textDark ? .black : .white
        let shadow = NSShadow()
        shadow.shadowColor = (t.textDark ? NSColor.white : NSColor.black).withAlphaComponent(t.textShadow)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        func run(_ s: String, _ alpha: CGFloat) -> NSAttributedString {
            NSAttributedString(string: s.replacingOccurrences(of: "\n", with: " "), attributes: [
                .font: font, .foregroundColor: base.withAlphaComponent(alpha), .shadow: shadow,
            ])
        }
        let s = NSMutableAttributedString()
        if let message {
            s.append(run(message, mode == .error ? 0.95 : 0.9))
        } else {
            s.append(run(written, 1.0))
            s.append(run(pending, t.pendingAlpha))
            s.append(run(partial, t.partialAlpha))
        }
        // 提示 / 报错放不下就把胶囊撑宽；转写的长文字不撑，交给跑马灯
        setWidth(fitting: message != nil ? ceil(s.size().width) + 4 : 0)
        marquee.set(s)
    }

    func hide(after delay: TimeInterval = 0) {
        hideWork?.cancel()
        logHeard()
        hideGen += 1
        let gen = hideGen
        let work = DispatchWorkItem { [weak self] in self?.fadeOut(gen) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// 淡的是整个窗口（窗口服务整体合成），玻璃的折射不会穿帮
    private func fadeOut(_ gen: Int) {
        guard gen == hideGen, panel.isVisible else { return }
        let panel = panel
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, gen == self.hideGen else { return }
            panel.orderOut(nil)
            panel.alphaValue = 1
            self.thinking.stop()
        })
    }

    // MARK: - 布局 / 材质

    private func applyTuning() {
        let t = tuning
        let H = CGFloat(t.height)
        let r = cornerRadius
        let m = margin

        // 窗口是一块固定大小的透明画布（按胶囊最宽能到多宽留），胶囊在里面居中、自己变宽变窄——
        // 窗口本身不动，变宽的动画只动玻璃
        let canvasW = (max(Self.maxPillWidth, CGFloat(t.pillWidth)) / 2).rounded(.up) * 2 + 2 * m
        panel.setContentSize(NSSize(width: canvasW, height: H + 2 * m))
        container.frame = NSRect(x: 0, y: 0, width: canvasW, height: H + 2 * m)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shadowLayer.shadowOpacity = Float(t.shadowOpacity)
        shadowLayer.shadowRadius = CGFloat(t.shadowRadius)
        shadowLayer.shadowOffset = CGSize(width: 0, height: -CGFloat(t.shadowOffsetY))
        CATransaction.commit()

        content.layer?.cornerRadius = r
        content.layer?.borderWidth = t.edgeHighlight > 0.01 ? 1 : 0
        content.layer?.borderColor = NSColor.white.withAlphaComponent(t.edgeHighlight).cgColor

        let icon = CGFloat(t.iconSize)
        appIcon.frame = NSRect(x: (H - icon) / 2 + 2, y: (H - icon) / 2, width: icon, height: icon)
        widthTween?.invalidate()
        widthTween = nil
        targetW = CGFloat(t.pillWidth)         // 先回到设置里的宽度；紧跟着的 redraw 会按内容再量一次
        pillW = targetW
        layoutInner()
        layoutPill()

        if #available(macOS 26, *), let g = glass as? GlassPillView {
            g.blurRadius = t.blurRadius
            g.distortAmount = t.distortAmount
            g.refractAmount = t.refractAmount
            g.refractHeight = t.refractHeight
            g.aberration = t.aberration
            g.applyPrivateKnobs(lensing: Int(t.lensing), scrim: Int(t.scrim), subdued: Int(t.subdued),
                                interaction: Int(t.interaction), adaptive: Int(t.adaptive))
            g.applyMaterial(variant: Int(t.variant), tintOpacity: t.tintOpacity, cornerRadius: r)
            glassVariant = Int(t.variant) >= 0 ? Int(t.variant) : nil
        } else if let e = glass as? NSVisualEffectView {
            e.layer?.cornerRadius = r
        }
        place(force: true)
    }

    private var cornerRadius: CGFloat {
        let H = CGFloat(tuning.height)
        return tuning.capsule ? H / 2 : min(CGFloat(tuning.cornerRadius), H / 2)
    }

    /// 图标右边那块内容区离胶囊左缘 / 右缘的距离
    private var textX: CGFloat { appIcon.frame.maxX + 10 }
    private let textTrailing: CGFloat = 16

    /// 内容至少要 contentWidth 这么宽才放得下：放不下就把胶囊撑宽（封顶 maxPillWidth），放得下就是设置里的宽度。
    /// 胶囊正显示着就带动画——玻璃是真的在改 frame，折射 / 高光跟着重算
    private func setWidth(fitting contentWidth: CGFloat) {
        let base = CGFloat(tuning.pillWidth)
        let need = contentWidth > 0 ? textX + contentWidth + textTrailing : 0
        let w = max(base, min(max(base, Self.maxPillWidth), ceil(need)))
        guard abs(w - targetW) > 0.5 else { return }
        targetW = w
        layoutInner()
        widthTween?.invalidate()
        widthTween = nil
        guard panel.isVisible, panel.alphaValue > 0.05 else { pillW = w; layoutPill(); return }
        let from = pillW, start = CACurrentMediaTime(), duration = 0.3
        let tween = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let p = min(1, (CACurrentMediaTime() - start) / duration)
            self.pillW = from + (w - from) * CGFloat(1 - pow(1 - p, 3))   // ease-out
            self.layoutPill()
            if p >= 1 { timer.invalidate(); self.widthTween = nil }
        }
        RunLoop.main.add(tween, forMode: .common)
        widthTween = tween
    }

    /// 玻璃 + 投影：按此刻的宽度在画布里居中
    private func layoutPill() {
        let H = CGFloat(tuning.height), r = cornerRadius
        // 宽度取偶数、画布也是偶数宽 → 居中后左缘一定落在整数点上。1x 的外接屏上半个点就是半个像素，
        // 玻璃的采样矩形对不齐像素格，淡出时会在胶囊外面留一圈方框细线（Retina 上看不出来）
        let w = (pillW / 2).rounded() * 2
        let pill = NSRect(x: (container.bounds.width - w) / 2, y: margin, width: w, height: H)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shadowLayer.frame = pill
        shadowLayer.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: pill.size), cornerWidth: r, cornerHeight: r, transform: nil)
        CATransaction.commit()
        glass?.frame = pill
        content.frame = NSRect(origin: .zero, size: pill.size)
    }

    /// 玻璃里面的东西：按最终宽度排
    private func layoutInner() {
        let t = tuning
        let W = targetW, H = CGFloat(t.height)
        let font = NSFont.systemFont(ofSize: t.fontSize, weight: .medium)
        let textH = ceil(font.ascender - font.descender + font.leading) + 2
        marquee.frame = NSRect(x: textX, y: floor((H - textH) / 2), width: W - textX - textTrailing, height: textH)
        wave.frame = NSRect(x: textX - 4, y: 9, width: max(0, W - textX - 6), height: max(0, H - 18))
        thinking.frame = marquee.frame
        thinking.needsLayout = true
    }

    private func place(force: Bool) {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        guard let screen else { return }
        // 显示中就别乱跳；但人换到另一块屏（比如在副屏全屏看视频）说话时要跟过去
        let strayed = panel.isVisible && !screen.frame.intersects(panel.frame)
        guard force || !panel.isVisible || strayed else { return }
        let size = panel.frame.size
        let x = screen.visibleFrame.midX - size.width / 2
        let y = screen.visibleFrame.minY + CGFloat(tuning.bottomOffset) - margin
        panel.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
    }
}

/// 单行"跑马灯"：文字放得下时居中；比框宽时只露尾巴，新字推进来时平滑左移，左缘渐隐提示前面还有。
final class MarqueeLabel: NSView {
    private let text = InkTextView()
    private let fade = CAGradientLayer()
    private var fresh = true                   // 刚从隐藏里出来：下一次 set 不做位移动画

    override func viewDidUnhide() {
        super.viewDidUnhide()
        fresh = true
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        text.wantsLayer = true
        addSubview(text)
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        fade.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor]
        fade.locations = [0, 0.12, 1]
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(_ attr: NSAttributedString) {
        let size = attr.size()
        let w = ceil(size.width) + 4
        let h = bounds.height
        let y: CGFloat = 0
        let overflow = w > bounds.width
        // 放得下就在图标右侧的区域里水平居中；放不下就靠右露尾巴（跑马灯）
        let targetX: CGFloat = overflow ? bounds.width - w : floor((bounds.width - w) / 2)
        // 同一段话在接着长（开头没变）才平滑挪位；刚露脸、或者换了一段新内容就直接摆到位——
        // 不然上一次说话留下的长文字位置还在，这次的短字会从左边滑进来
        let old = text.attributed.string
        let continuing = !fresh && !old.isEmpty && attr.string.first == old.first
        fresh = false
        text.attributed = attr
        text.frame.size = NSSize(width: w, height: h)
        if !continuing {
            text.layer?.removeAllAnimations()   // 上一段的位移动画可能还没走完
            text.frame.origin = NSPoint(x: targetX, y: y)
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                text.animator().setFrameOrigin(NSPoint(x: targetX, y: y))
            }
        }
        if overflow {
            fade.frame = bounds
            layer?.mask = fade
        } else {
            layer?.mask = nil
        }
    }

    override func layout() {
        super.layout()
        if layer?.mask != nil { fade.frame = bounds }
        text.frame.size.height = bounds.height
        text.frame.origin.y = 0
    }
}

/// 单行文字，按字形实际墨迹框在视图里垂直居中（中英混排、有没有下伸字母都一样居中）
final class InkTextView: NSView {
    var attributed = NSAttributedString() { didSet { needsDisplay = true } }
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard attributed.length > 0, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let line = CTLineCreateWithAttributedString(attributed)
        let ink = CTLineGetImageBounds(line, ctx)   // 相对基线的墨迹框
        let baselineY = bounds.midY - ink.midY
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: 2, y: baselineY)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
