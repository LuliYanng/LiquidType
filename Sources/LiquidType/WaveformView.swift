import AppKit
import QuartzCore

/// 胶囊里的音量柱：几根定在原地的竖条，说话时跟着音量上下跳，不出声就缩成一排小圆点。
/// 每根自己带一点快慢和相位差，所以看着是一团在动，不是一整块上下平移。
/// 起得快、落得慢（下面的 attack / release）——音量表都是这么做的，跟着每个字往上蹿、落下来拖一点尾巴。
final class WaveformView: NSView {
    /// 每帧取一次 0..1 音量（设置页预览接模拟语音）；不设就等 setLevel 喂
    var levelSource: (() -> CGFloat)?

    private var count = 5
    private var barWidth: CGFloat = 4
    private var barGap: CGFloat = 5
    private var speed: Double = 1
    private var dark = false

    private var level: CGFloat = 0          // 当前音量
    private var incoming: CGFloat = 0       // 上一帧到这一帧之间喂进来的最响的一次
    private var gotLevel = false
    private var levelAt = CACurrentMediaTime()
    private var heights: [CGFloat] = []     // 每根现在多高，0..1
    private var lastTick = CACurrentMediaTime()
    private var link: CADisplayLink?

    private static let attack = 0.035
    private static let release = 0.13

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { link?.invalidate() }

    override var isOpaque: Bool { false }

    func apply(_ t: HUDTuning) {
        count = max(1, Int(t.barCount))
        barWidth = CGFloat(t.barWidth)
        barGap = CGFloat(t.barGap)
        speed = t.barSpeed
        dark = t.textDark
    }

    /// 喂当前音量 0..1。一帧里喂几次都行，取最响的那次：
    /// 平均下来正常说话就是一条温吞的直线，取峰值才跳得出字与字的起伏
    func setLevel(_ v: CGFloat) {
        incoming = max(incoming, min(1, max(0, v)))
        gotLevel = true
        levelAt = CACurrentMediaTime()
    }

    /// 开始走帧。胶囊每次露脸调一次；藏起来或者窗口收走了自己会停
    func begin() {
        guard link == nil else { return }
        let l = displayLink(target: self, selector: #selector(tick))
        l.add(to: .main, forMode: .common)
        link = l
        lastTick = CACurrentMediaTime()
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    override func viewDidHide() { stop() }
    override func viewDidUnhide() { if window != nil { begin() } }
    override func viewDidMoveToWindow() { if window == nil { stop() } }

    @objc private func tick() {
        guard window?.isVisible == true, !isHiddenOrHasHiddenAncestor else { stop(); return }
        let now = CACurrentMediaTime()
        let dt = min(0.1, max(0.001, now - lastTick))
        lastTick = now

        if let levelSource {
            level = levelSource()
        } else if gotLevel {
            level = incoming
            incoming = 0
            gotLevel = false
        } else if now - levelAt > 0.2 {
            // 电平断了（麦克风掉了）：别把最后一口气定格在那儿
            level *= CGFloat(exp(-dt / Self.release))
        }

        if heights.count != count { heights = Array(repeating: 0, count: count) }
        let v = min(1, max(0, level))
        for i in 0..<count {
            let wobble = 0.62 + 0.38 * CGFloat(sin(now * speed * (2.6 + 0.73 * Double(i)) + Double(i) * 1.9))
            let target = v * shape(i) * wobble
            let tau = target > heights[i] ? Self.attack : Self.release
            heights[i] += (target - heights[i]) * CGFloat(1 - exp(-dt / tau))
        }
        needsDisplay = true
    }

    /// 中间高、两头矮：一排条子这样才有个形状
    private func shape(_ i: Int) -> CGFloat {
        guard count > 1 else { return 1 }
        return 0.58 + 0.42 * CGFloat(sin(Double.pi * (Double(i) + 0.5) / Double(count)))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, bounds.width > 2, bounds.height > 2 else { return }
        var w = barWidth
        var pitch = barWidth + barGap
        // 胶囊被调得太窄就按比例挤一挤，宁可细一点也不要溢出去被切掉
        if CGFloat(count) * pitch - barGap > bounds.width {
            pitch = bounds.width / CGFloat(count)
            w = min(w, pitch * 0.55)
        }
        let total = CGFloat(count) * pitch - (pitch - w)
        let first = (bounds.width - total) / 2 + w / 2
        let midY = bounds.midY
        let minHalf = w / 2
        let maxHalf = bounds.height / 2

        ctx.setFillColor((dark ? NSColor.black : NSColor.white).withAlphaComponent(0.92).cgColor)
        for i in 0..<count {
            let h = i < heights.count ? heights[i] : 0
            let half = minHalf + (maxHalf - minHalf) * min(1, max(0, h))
            let x = first + CGFloat(i) * pitch
            let r = CGRect(x: x - w / 2, y: midY - half, width: w, height: half * 2)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: minHalf, cornerHeight: minHalf, transform: nil))
        }
        ctx.fillPath()
    }

    /// 没有麦克风时的模拟语音：音节包络 × 句间停顿，t 为秒。
    /// 停顿比真人短（每 7 秒停 1.6 秒）：设置页里刚点「波形」就撞上一段长平线，会以为坏了
    static func fakeSpeech(_ t: Double) -> CGFloat {
        let syllable = max(0, sin(t * 7.3) + 0.8 * sin(t * 3.1 + 1) + 0.6 * sin(t * 1.3)) / 2.4
        let phrase = sin(t * 0.9) > -0.75 ? 1.0 : 0.03
        return CGFloat(min(1, syllable * phrase * 1.25))
    }
}
