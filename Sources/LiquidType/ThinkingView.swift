import AppKit
import QuartzCore

/// 一个状态词 + 三个依次轻跳的小点。两处用：松开热键之后、字落进 app 之前的那一两秒（「思考中」，
/// 文字模式和波形模式到这一步都换成它）；文字模式刚唤起、还没识别出字的时候（「正在听」）。
final class ThinkingView: NSView {
    private let label = InkTextView()
    private let dots = (0..<3).map { _ in CALayer() }
    private var dotSize: CGFloat = 4
    private var baselineY: CGFloat = 0
    private var hopping = true
    /// 状态词 + 点一共多宽（apply 之后才准）：胶囊太窄放不下时 HUD 按它撑宽
    private(set) var contentWidth: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(label)
        dots.forEach { layer?.addSublayer($0) }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// hopping = false：不画小圆点，状态词后面跟一个普通的省略号（「正在听…」只是出字前的占位，不抢眼）
    func apply(_ t: HUDTuning, text: String, hopping: Bool) {
        self.hopping = hopping
        let font = NSFont.systemFont(ofSize: t.fontSize, weight: .medium)
        let base: NSColor = t.textDark ? .black : .white
        let shadowColor = (t.textDark ? NSColor.white : NSColor.black).withAlphaComponent(t.textShadow)
        let shadow = NSShadow()
        shadow.shadowColor = shadowColor
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        label.attributed = NSAttributedString(string: hopping ? text : text + "…", attributes: [
            .font: font, .foregroundColor: base.withAlphaComponent(0.9), .shadow: shadow,
        ])
        dotSize = max(3, (t.fontSize * 0.28).rounded())
        for d in dots {
            d.isHidden = !hopping
            d.backgroundColor = base.withAlphaComponent(0.9).cgColor
            d.cornerRadius = dotSize / 2
            d.shadowColor = shadowColor.cgColor
            d.shadowOpacity = 1
            d.shadowRadius = 3
            d.shadowOffset = CGSize(width: 0, height: -1)
        }
        contentWidth = ceil(label.attributed.size().width) + 4 + (hopping ? dotSize * 1.5 + dotSize * 5 : 0)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let attr = label.attributed
        let textW = ceil(attr.size().width) + 4
        let step = dotSize * 2
        let dotsW = step * CGFloat(dots.count - 1) + dotSize
        let gap = dotSize * 1.5
        let x0 = floor((bounds.width - textW - (hopping ? gap + dotsW : 0)) / 2)
        label.frame = NSRect(x: x0, y: 0, width: textW, height: bounds.height)
        // 点坐在文字基线上，跟省略号一个位置（InkTextView 按墨迹框垂直居中，基线照它的算法推）
        let ink = attr.length > 0 ? CTLineGetImageBounds(CTLineCreateWithAttributedString(attr), nil) : .zero
        baselineY = bounds.midY - ink.midY
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, d) in dots.enumerated() {
            d.frame = CGRect(x: x0 + textW + gap + step * CGFloat(i), y: baselineY, width: dotSize, height: dotSize)
        }
        CATransaction.commit()
    }

    /// 窗口撤下时系统会把 layer 动画清掉，所以每次露脸都查一遍、没有就补上
    func start() {
        guard hopping else { stop(); return }
        for (i, d) in dots.enumerated() where d.animation(forKey: "hop") == nil {
            let s = 0.15 * Double(i)
            let hop = CAKeyframeAnimation(keyPath: "transform.translation.y")
            hop.values = [0, 0, dotSize * 0.8, 0, 0]
            hop.keyTimes = [0, s, s + 0.18, s + 0.36, 1].map { NSNumber(value: $0) }
            hop.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 4)
            hop.duration = 1.0
            hop.repeatCount = .infinity
            d.add(hop, forKey: "hop")
        }
    }

    func stop() {
        dots.forEach { $0.removeAnimation(forKey: "hop") }
    }
}
