import AppKit
import QuartzCore

/// NSGlassEffectView + 内部滤镜微调
/// （layer 树逆向：glassBackground 管背景采样/折射，displacementMap 管内容扭曲，
/// glassForeground 管色散；私有整数旋钮 KVC）。写入时序：系统在每次几何变化后
/// 重建 filters，直接在 layout() 里写会被同一事务覆盖——借自有子层的 layoutSublayers
/// （CA layout 阶段，在系统重写之后）补写才稳。
@available(macOS 26.0, *)
final class GlassPillView: NSGlassEffectView {
    var blurRadius: Double = 0 { didSet { if blurRadius != oldValue { scheduleTweaks() } } }
    var distortAmount: Double = 65 { didSet { if distortAmount != oldValue { scheduleTweaks() } } }
    var refractAmount: Double = 60 { didSet { if refractAmount != oldValue { scheduleTweaks() } } }
    var refractHeight: Double = 20 { didSet { if refractHeight != oldValue { scheduleTweaks() } } }
    var aberration: Double = 0 { didSet { if aberration != oldValue { scheduleTweaks() } } }
    private var filterRetry = 0
    private var initial: [String: Any] = [:]

    private final class PostLayoutHook: CALayer {
        var onLayout: (() -> Void)?
        override func layoutSublayers() {
            super.layoutSublayers()
            onLayout?()
        }
    }
    private lazy var hook: PostLayoutHook = {
        let l = PostLayoutHook()
        l.frame = .zero
        l.onLayout = { [weak self] in self?.applyFilterTweaks() }
        return l
    }()

    /// variant 先设（重建内部 sublayer），cornerRadius 最后设
    func applyMaterial(variant: Int, tintOpacity: Double, cornerRadius: CGFloat) {
        if style != .clear { style = .clear }
        if variant >= 0, responds(to: Selector(("set_variant:"))),
           (value(forKey: "_variant") as? Int) != variant {
            setValue(variant, forKey: "_variant")
        }
        let tint: NSColor? = tintOpacity > 0 ? .black.withAlphaComponent(tintOpacity) : nil
        if tintColor != tint { tintColor = tint }
        if self.cornerRadius != cornerRadius { self.cornerRadius = cornerRadius }
    }

    /// 私有整数旋钮：-1 = 恢复系统初始值。值域按隔离探针结论钳制
    /// （interactionState/adaptiveAppearance 只认 0-2，3+ 撞断言直接崩）
    func applyPrivateKnobs(lensing: Int, scrim: Int, subdued: Int, interaction: Int, adaptive: Int) {
        let knobs: [(String, Int, Int)] = [
            ("_contentLensing", lensing, 5), ("_scrimState", scrim, 5),
            ("_subduedState", subdued, 5), ("_interactionState", interaction, 2),
            ("_adaptiveAppearance", adaptive, 2),
        ]
        for (key, raw, cap) in knobs {
            let sel = Selector(("set" + key + ":"))
            guard responds(to: sel) else { continue }
            if initial[key] == nil { initial[key] = value(forKey: key) ?? NSNull() }
            if raw < 0 {
                if let v = initial[key], !(v is NSNull), (value(forKey: key) as? Int) != (v as? Int) {
                    setValue(v, forKey: key)
                }
            } else {
                let v = min(raw, cap)
                if (value(forKey: key) as? Int) != v { setValue(v, forKey: key) }
            }
        }
    }

    private func scheduleTweaks() {
        if hook.superlayer == nil, let root = layer { root.addSublayer(hook) }
        hook.setNeedsLayout()
    }

    override func layout() {
        super.layout()
        scheduleTweaks()
    }

    private static let caFilterClass = NSClassFromString("CAFilter") as? NSObject.Type

    private func makeBlurFilter(radius: Double) -> AnyObject? {
        guard let cls = Self.caFilterClass else { return nil }
        let sel = Selector(("filterWithType:"))
        guard cls.responds(to: sel), let f = cls.perform(sel, with: "gaussianBlur")?.takeUnretainedValue() else { return nil }
        f.setValue(radius, forKey: "inputRadius")
        return f
    }

    private struct ScaledState { var lastSys: Double?; var lastWritten: Double? }
    private var scaled: [String: ScaledState] = [:]

    /// 倍率写法：目标 = 系统按尺寸算出的值 × (用户值 / 系统封顶)
    private func applyScaled(_ l: CALayer, _ keyPath: String, cap: Double, user: Double) {
        guard let cur = l.value(forKeyPath: keyPath) as? Double else { return }
        var st = scaled[keyPath] ?? ScaledState()
        let sys: Double
        if let w = st.lastWritten, abs(cur - w) < 0.001, let ls = st.lastSys { sys = ls } else { sys = cur }
        let target = sys * (user / cap)
        if abs(cur - target) > 0.01 { l.setValue(target, forKeyPath: keyPath) }
        st.lastSys = sys
        st.lastWritten = target
        scaled[keyPath] = st
    }

    private func setIfChanged(_ l: CALayer, _ keyPath: String, _ value: Double) {
        if let cur = l.value(forKeyPath: keyPath) as? Double, abs(cur - value) < 0.01 { return }
        l.setValue(value, forKeyPath: keyPath)
    }

    private func filterName(_ f: Any) -> String { ((f as AnyObject).value(forKey: "name") as? String) ?? "" }

    private func applyFilterTweaks() {
        guard let root = layer else { return }
        var found = false
        func walk(_ l: CALayer) {
            if let fs = l.filters, !fs.isEmpty {
                let names = fs.map(filterName)
                if names.contains("glassBackground") {
                    found = true
                    let wantBlur = blurRadius > 0.5
                    let curBlur = fs.first { filterName($0) == "gaussianBlur" }
                    let curRadius = (curBlur as AnyObject?)?.value(forKey: "inputRadius") as? Double
                    let blurChanged = wantBlur != (curBlur != nil) || (wantBlur && abs((curRadius ?? -1) - blurRadius) > 0.01)
                    if blurChanged {
                        var newFilters = fs.filter { filterName($0) != "gaussianBlur" }
                        if wantBlur, let blur = makeBlurFilter(radius: blurRadius) { newFilters.append(blur) }
                        l.filters = newFilters
                    }
                    applyScaled(l, "filters.glassBackground.inputInnerRefractionAmount", cap: 60, user: refractAmount)
                    applyScaled(l, "filters.glassBackground.inputInnerRefractionHeight", cap: 20, user: refractHeight)
                }
                if names.contains("glassForeground") {
                    setIfChanged(l, "filters.glassForeground.inputAberrationAmount", aberration)
                }
                if names.contains("displacementMap") {
                    applyScaled(l, "filters.displacementMap.inputAmount", cap: 65, user: distortAmount)
                }
            }
            for sub in l.sublayers ?? [] { walk(sub) }
        }
        walk(root)
        if found {
            filterRetry = 0
        } else if filterRetry < 5 {
            filterRetry += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.scheduleTweaks() }
        }
    }
}
