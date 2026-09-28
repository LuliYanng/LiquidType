import AppKit

/// The notice after hotwords were learned from the user's own edits. It shows up a while after they
/// finished talking, so there's no app icon, only centered text. One word: a single sentence, like any
/// other notice. Several: all of them on top (wrapping onto more lines when needed) and a dimmer caption
/// underneath; the HUD grows the pill taller to fit.
final class LearnedNoticeView: NSView {
    private struct Row { let line: CTLine; let width: CGFloat; let capHeight: CGFloat; let gapBelow: CGFloat }
    private var rows: [Row] = []
    /// Size of the text block, cap height to cap height (valid after apply): the HUD sizes the pill around it
    private(set) var contentSize: NSSize = .zero

    override var isFlipped: Bool { false }

    static let weights: [NSFont.Weight] = [.regular, .medium, .semibold, .bold, .heavy]
    private static func weight(_ index: Double) -> NSFont.Weight { weights[max(0, min(weights.count - 1, Int(index.rounded())))] }

    /// `removed`: Undo was pressed, and the notice says so in one line instead
    func apply(_ t: HUDTuning, words: [String], maxWidth: CGFloat, removed: Bool = false) {
        let g = t.learnedGlass
        let base: NSColor = g.textDark ? .black : .white
        let shadow = NSShadow()
        shadow.shadowColor = (g.textDark ? NSColor.white : NSColor.black).withAlphaComponent(g.textShadow)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        // The learned words are what the notice is about: bold and full white, the words around them
        // regular and dimmer, so a lone word stands out of its sentence at a glance. Styled by its own
        // learned* settings, not the pill's
        let wordFont = NSFont.systemFont(ofSize: t.learnedWordSize, weight: Self.weight(t.learnedWordWeight))
        let textFont = NSFont.systemFont(ofSize: t.learnedWordSize, weight: Self.weight(t.learnedTextWeight))
        let captionFont = NSFont.systemFont(ofSize: t.learnedCaptionSize, weight: Self.weight(t.learnedTextWeight))
        func run(_ s: String, _ font: NSFont, _ alpha: CGFloat) -> NSAttributedString {
            NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: base.withAlphaComponent(alpha), .shadow: shadow])
        }
        func row(_ a: NSAttributedString, _ font: NSFont, gapBelow: CGFloat) -> Row {
            Row(line: CTLineCreateWithAttributedString(a), width: ceil(a.size().width), capHeight: font.capHeight, gapBelow: gapBelow)
        }

        /// One line, dim text with its key part bold and bright
        func sentence(_ s: (text: String, highlight: NSRange)) -> NSAttributedString {
            let line = NSMutableAttributedString(attributedString: run(s.text, textFont, t.learnedTextAlpha))
            let key = (s.text as NSString).substring(with: s.highlight)
            line.replaceCharacters(in: s.highlight, with: run(key, wordFont, 1))
            return line
        }

        rows = []
        if removed {
            rows.append(row(sentence(HUDCopy.learnedUndone(words)), wordFont, gapBelow: 0))
        } else if words.count == 1 {
            rows.append(row(sentence(HUDCopy.learned(words[0])), wordFont, gapBelow: 0))
        } else {
            // Greedy wrap, never breaking inside a word; the separator is dimmer than the words
            let sep = run("  ·  ", wordFont, t.learnedSepAlpha)
            var lines: [NSMutableAttributedString] = []
            for w in words {
                let word = run(w, wordFont, 1)
                if let last = lines.last, last.size().width + sep.size().width + word.size().width <= maxWidth {
                    last.append(sep); last.append(word)
                } else {
                    lines.append(NSMutableAttributedString(attributedString: word))
                }
            }
            for (i, l) in lines.enumerated() {
                rows.append(row(l, wordFont, gapBelow: i == lines.count - 1 ? t.learnedCaptionGap : t.learnedLineGap))
            }
            rows.append(row(run(HUDCopy.learnedCaption, captionFont, t.learnedCaptionAlpha), captionFont, gapBelow: 0))
        }
        contentSize = NSSize(width: rows.map(\.width).max() ?? 0,
                             height: ceil(rows.reduce(0) { $0 + $1.capHeight + $1.gapBelow }))
        needsDisplay = true
    }

    /// Rows are stacked by cap height and the block is centered on that, so a lone line sits exactly
    /// where the pill's other notices do, whatever descenders or CJK glyphs it has
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        var top = bounds.midY + contentSize.height / 2
        ctx.saveGState()
        ctx.textMatrix = .identity
        for r in rows {
            ctx.textPosition = CGPoint(x: floor((bounds.width - r.width) / 2), y: top - r.capHeight)
            CTLineDraw(r.line, ctx)
            top -= r.capHeight + r.gapBelow
        }
        ctx.restoreGState()
    }
}

/// The learned notice's Undo: a small circle whose ring runs down with the time the notice has left on
/// screen. The pill's window never activates the app, so clicking it leaves focus in the user's text field
final class RingButton: NSView {
    static let diameter: CGFloat = 24
    /// SF Symbol in the middle while it can still be pressed
    static let symbolName = "arrow.uturn.backward"
    var onClick: (() -> Void)?
    private let fill = CAShapeLayer()
    private let track = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let icon = NSImageView()
    private var hovered = false { didSet { restyle() } }
    private var pressed = false { didSet { restyle() } }
    private var dark = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for l in [fill, track, ring] { layer?.addSublayer(l) }
        for l in [track, ring] {
            l.fillColor = nil
            l.lineWidth = 2
        }
        ring.lineCap = .round
        icon.imageScaling = .scaleProportionallyDown
        addSubview(icon)
        setAccessibilityRole(.button)
        setAccessibilityLabel(HUDCopy.learnedUndo)
        toolTip = HUDCopy.learnedUndo
        reset(dark: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A fresh notice: full ring, nothing running
    func reset(dark: Bool) {
        hovered = false
        pressed = false
        ring.removeAllAnimations()
        ring.strokeEnd = 1
        setDark(dark)
    }

    func setDark(_ dark: Bool) {
        self.dark = dark
        let cfg = NSImage.SymbolConfiguration(pointSize: 9.5, weight: .bold)
        icon.image = NSImage(systemSymbolName: Self.symbolName, accessibilityDescription: HUDCopy.learnedUndo)?
            .withSymbolConfiguration(cfg)
        restyle()
    }

    /// Run the ring down from wherever it is to empty over `duration`
    func countDown(duration: TimeInterval) {
        // Mid-countdown, start from what's on screen; otherwise from the model value. Right after reset() the
        // presentation layer still shows the previous notice's empty ring, and reading it ran 0 → 0
        let running = ring.animation(forKey: "countdown") != nil
        let from = running ? (ring.presentation() ?? ring).strokeEnd : ring.strokeEnd
        ring.removeAllAnimations()
        ring.strokeEnd = 0
        let a = CABasicAnimation(keyPath: "strokeEnd")
        a.fromValue = from
        a.toValue = 0
        a.duration = max(0.1, duration)
        a.timingFunction = CAMediaTimingFunction(name: .linear)
        ring.add(a, forKey: "countdown")
    }

    /// Stop the ring where it is (the pointer is resting on the notice)
    func freeze() {
        let now = (ring.presentation() ?? ring).strokeEnd
        ring.removeAllAnimations()
        ring.strokeEnd = now
    }

    override func layout() {
        super.layout()
        let b = bounds.insetBy(dx: 1, dy: 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.path = CGPath(ellipseIn: b, transform: nil)
        track.path = CGPath(ellipseIn: b, transform: nil)
        // From 12 o'clock, clockwise: as strokeEnd runs down the ring winds back to the top
        let ringPath = CGMutablePath()
        ringPath.addArc(center: CGPoint(x: b.midX, y: b.midY), radius: b.width / 2, startAngle: .pi / 2,
                        endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        ring.path = ringPath
        for l in [fill, track, ring] { l.frame = bounds }
        CATransaction.commit()
        icon.frame = bounds.insetBy(dx: 5, dy: 5)
    }

    /// Same ink as the notice's text: a faint wash inside, a dim track and a bright running ring
    private func restyle() {
        let ink: NSColor = dark ? .black : .white
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.fillColor = ink.withAlphaComponent(pressed ? 0.3 : hovered ? 0.2 : 0.08).cgColor
        track.strokeColor = ink.withAlphaComponent(0.18).cgColor
        ring.strokeColor = ink.withAlphaComponent(0.85).cgColor
        CATransaction.commit()
        icon.contentTintColor = ink.withAlphaComponent(0.95)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false; pressed = false }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

/// Covers the pill to notice the pointer resting on it (the learned notice holds still meanwhile).
/// Never takes a click itself
final class HoverWatcher: NSView {
    var onChange: ((Bool) -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { onChange?(true) }
    override func mouseExited(with event: NSEvent) { onChange?(false) }
}
