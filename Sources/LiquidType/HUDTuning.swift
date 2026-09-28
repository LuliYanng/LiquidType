import Foundation
import Combine

/// 说话时胶囊里放什么：实时转写，还是只放一条跟着声音起伏的波形（嫌字跳来跳去分心的人用）
enum PillContent: String, CaseIterable {
    case transcript, waveform
}

/// 浮窗全部可调参数，改动即存 UserDefaults（前缀 hud.）。
final class HUDTuning: ObservableObject {
    static let shared = HUDTuning()
    private static let prefix = "hud."
    private var loading = true

    // —— 显示方式 ——
    @Published var content: PillContent = .transcript { didSet { save() } }

    // —— 几何 ——
    @Published var width: Double = 240 { didSet { save() } }
    @Published var height: Double = 46 { didSet { save() } }
    /// 胶囊 = 圆角永远取高度一半；关掉才用 cornerRadius
    @Published var capsule: Bool = true { didSet { save() } }
    @Published var cornerRadius: Double = 25 { didSet { save() } }
    /// 距屏幕可见区底部
    @Published var bottomOffset: Double = 32 { didSet { save() } }
    @Published var iconSize: Double = 30 { didSet { save() } }
    @Published var fontSize: Double = 15 { didSet { save() } }

    // —— 玻璃材质 ——
    /// 私有变体号（KVC _variant），-1 = 公开 .clear。11=frosted（默认）；19=chromatic 真折射；6=avplayer 深色；13=纯透明
    @Published var variant: Double = 11 { didSet { save() } }
    /// 黑色染色浓度（tintColor alpha），只有部分变体吃（6 明显，11/19 无感）
    @Published var tintOpacity: Double = 0 { didSet { save() } }
    /// 追加 gaussianBlur 半径，0 = 系统原样
    @Published var blurRadius: Double = 0.5 { didSet { save() } }
    /// 内容层扭曲（displacementMap inputAmount，系统默认 65）
    @Published var distortAmount: Double = 0 { didSet { save() } }
    /// 背景扭曲强度（inputInnerRefractionAmount，系统默认 60）
    @Published var refractAmount: Double = 73 { didSet { save() } }
    /// 背景扭曲带宽度（inputInnerRefractionHeight，系统默认 20）
    @Published var refractHeight: Double = 20 { didSet { save() } }
    /// RGB 色散（inputAberrationAmount，系统默认 0）
    @Published var aberration: Double = 0 { didSet { save() } }
    // 私有整数旋钮，-1 = 不碰
    @Published var lensing: Double = -1 { didSet { save() } }
    @Published var scrim: Double = -1 { didSet { save() } }
    @Published var subdued: Double = -1 { didSet { save() } }
    @Published var interaction: Double = -1 { didSet { save() } }
    @Published var adaptive: Double = -1 { didSet { save() } }

    // —— 悬浮感 ——
    @Published var shadowOpacity: Double = 0.21 { didSet { save() } }
    @Published var shadowRadius: Double = 9 { didSet { save() } }
    @Published var shadowOffsetY: Double = 9 { didSet { save() } }
    /// 1pt 白色描边高光的透明度（0 = 无）
    @Published var edgeHighlight: Double = 0.10 { didSet { save() } }

    // —— 文字 ——
    @Published var textDark: Bool = false { didSet { save() } }
    @Published var pendingAlpha: Double = 1 { didSet { save() } }
    @Published var partialAlpha: Double = 1 { didSet { save() } }
    @Published var textShadow: Double = 0 { didSet { save() } }

    // —— 音量柱（显示方式选「波形」时）——
    /// 波形模式的胶囊宽度：里面只有图标和几根条，比文字模式窄一大截
    @Published var barPillWidth: Double = 116 { didSet { save() } }
    /// 几根条 / 每根多宽 / 根与根之间留多少
    @Published var barCount: Double = 5 { didSet { save() } }
    @Published var barWidth: Double = 4 { didSet { save() } }
    @Published var barGap: Double = 5 { didSet { save() } }
    /// 跳动快慢（各根之间的快慢差也跟着缩放）
    @Published var barSpeed: Double = 1 { didSet { save() } }
    /// 麦克风音量按分贝映射：这个 dBFS 以下算静音。越低越灵敏，太低底噪也会晃
    @Published var barFloor: Double = -55 { didSet { save() } }
    /// 满格至少比门限高这么多 dB（说得再响也只按这个量程算）。调小 = 柱子更容易顶到头
    @Published var barRange: Double = 18 { didSet { save() } }

    // —— Learned-hotword notice (its own set, so tuning it leaves the dictation pill alone) ——
    @Published var learnedWordSize: Double = 15 { didSet { save() } }
    /// Index into LearnedNoticeView.weights: 0 regular … 3 bold … 4 heavy
    @Published var learnedWordWeight: Double = 3 { didSet { save() } }
    /// Weight of everything that isn't a learned word: the one-word sentence and the caption
    @Published var learnedTextWeight: Double = 0 { didSet { save() } }
    /// Brightness of the sentence around a single word
    @Published var learnedTextAlpha: Double = 0.75 { didSet { save() } }
    @Published var learnedCaptionSize: Double = 12 { didSet { save() } }
    @Published var learnedCaptionAlpha: Double = 0.7 { didSet { save() } }
    @Published var learnedSepAlpha: Double = 0.45 { didSet { save() } }
    /// Several words: space between wrapped lines of words, and between the words and the caption
    @Published var learnedLineGap: Double = 9 { didSet { save() } }
    @Published var learnedCaptionGap: Double = 11 { didSet { save() } }
    @Published var learnedPadX: Double = 22 { didSet { save() } }
    @Published var learnedPadY: Double = 17 { didSet { save() } }
    /// -1 = same corners as the pill; otherwise its own radius (capped at half the notice's height)
    @Published var learnedRadius: Double = -1 { didSet { save() } }
    /// Off: the notice wears the pill's glass. On: the learned*Glass set below
    @Published var learnedOwnGlass: Bool = false { didSet { save() } }
    @Published var learnedVariant: Double = 11 { didSet { save() } }
    @Published var learnedTintOpacity: Double = 0 { didSet { save() } }
    @Published var learnedBlurRadius: Double = 0.5 { didSet { save() } }
    @Published var learnedDistortAmount: Double = 0 { didSet { save() } }
    @Published var learnedRefractAmount: Double = 73 { didSet { save() } }
    @Published var learnedRefractHeight: Double = 20 { didSet { save() } }
    @Published var learnedAberration: Double = 0 { didSet { save() } }
    @Published var learnedShadowOpacity: Double = 0.21 { didSet { save() } }
    @Published var learnedShadowRadius: Double = 9 { didSet { save() } }
    @Published var learnedShadowOffsetY: Double = 9 { didSet { save() } }
    @Published var learnedEdgeHighlight: Double = 0.10 { didSet { save() } }
    @Published var learnedTextDark: Bool = false { didSet { save() } }
    @Published var learnedTextShadow: Double = 0 { didSet { save() } }

    /// The glass-and-text look, one for the pill and one for the learned notice
    struct GlassStyle {
        var variant, tintOpacity, blurRadius, distortAmount, refractAmount, refractHeight, aberration: Double
        var shadowOpacity, shadowRadius, shadowOffsetY, edgeHighlight: Double
        var textDark: Bool
        var textShadow: Double
    }

    var pillGlass: GlassStyle {
        GlassStyle(variant: variant, tintOpacity: tintOpacity, blurRadius: blurRadius, distortAmount: distortAmount,
                   refractAmount: refractAmount, refractHeight: refractHeight, aberration: aberration,
                   shadowOpacity: shadowOpacity, shadowRadius: shadowRadius, shadowOffsetY: shadowOffsetY,
                   edgeHighlight: edgeHighlight, textDark: textDark, textShadow: textShadow)
    }

    var learnedGlass: GlassStyle {
        guard learnedOwnGlass else { return pillGlass }
        return GlassStyle(variant: learnedVariant, tintOpacity: learnedTintOpacity, blurRadius: learnedBlurRadius,
                          distortAmount: learnedDistortAmount, refractAmount: learnedRefractAmount,
                          refractHeight: learnedRefractHeight, aberration: learnedAberration,
                          shadowOpacity: learnedShadowOpacity, shadowRadius: learnedShadowRadius,
                          shadowOffsetY: learnedShadowOffsetY, edgeHighlight: learnedEdgeHighlight,
                          textDark: learnedTextDark, textShadow: learnedTextShadow)
    }

    /// 当前显示方式下胶囊实际多宽
    var pillWidth: Double { content == .waveform ? barPillWidth : width }

    private init() {
        let d = UserDefaults.standard
        content = PillContent(rawValue: d.string(forKey: Self.prefix + "content") ?? "") ?? content
        func dbl(_ k: String, _ v: Double) -> Double { d.object(forKey: Self.prefix + k) == nil ? v : d.double(forKey: Self.prefix + k) }
        func bol(_ k: String, _ v: Bool) -> Bool { d.object(forKey: Self.prefix + k) == nil ? v : d.bool(forKey: Self.prefix + k) }
        width = dbl("width", width); height = dbl("height", height); capsule = bol("capsule", capsule)
        cornerRadius = dbl("cornerRadius", cornerRadius); bottomOffset = dbl("bottomOffset", bottomOffset)
        iconSize = dbl("iconSize", iconSize); fontSize = dbl("fontSize", fontSize)
        variant = dbl("variant", variant); tintOpacity = dbl("tintOpacity", tintOpacity); blurRadius = dbl("blurRadius", blurRadius)
        distortAmount = dbl("distortAmount", distortAmount); refractAmount = dbl("refractAmount", refractAmount)
        refractHeight = dbl("refractHeight", refractHeight); aberration = dbl("aberration", aberration)
        lensing = dbl("lensing", lensing); scrim = dbl("scrim", scrim); subdued = dbl("subdued", subdued)
        interaction = dbl("interaction", interaction); adaptive = dbl("adaptive", adaptive)
        shadowOpacity = dbl("shadowOpacity", shadowOpacity); shadowRadius = dbl("shadowRadius", shadowRadius)
        shadowOffsetY = dbl("shadowOffsetY", shadowOffsetY); edgeHighlight = dbl("edgeHighlight", edgeHighlight)
        textDark = bol("textDark", textDark); pendingAlpha = dbl("pendingAlpha", pendingAlpha)
        partialAlpha = dbl("partialAlpha", partialAlpha); textShadow = dbl("textShadow", textShadow)
        barPillWidth = dbl("barPillWidth", barPillWidth); barCount = dbl("barCount", barCount)
        barWidth = dbl("barWidth", barWidth); barGap = dbl("barGap", barGap)
        barSpeed = dbl("barSpeed", barSpeed); barFloor = dbl("barFloor", barFloor)
        barRange = dbl("barRange", barRange)
        learnedWordSize = dbl("learnedWordSize", learnedWordSize); learnedWordWeight = dbl("learnedWordWeight", learnedWordWeight)
        learnedTextWeight = dbl("learnedTextWeight", learnedTextWeight); learnedTextAlpha = dbl("learnedTextAlpha", learnedTextAlpha)
        learnedCaptionSize = dbl("learnedCaptionSize", learnedCaptionSize); learnedCaptionAlpha = dbl("learnedCaptionAlpha", learnedCaptionAlpha)
        learnedSepAlpha = dbl("learnedSepAlpha", learnedSepAlpha); learnedLineGap = dbl("learnedLineGap", learnedLineGap)
        learnedCaptionGap = dbl("learnedCaptionGap", learnedCaptionGap); learnedPadX = dbl("learnedPadX", learnedPadX)
        learnedPadY = dbl("learnedPadY", learnedPadY); learnedRadius = dbl("learnedRadius", learnedRadius)
        learnedOwnGlass = bol("learnedOwnGlass", learnedOwnGlass); learnedVariant = dbl("learnedVariant", learnedVariant)
        learnedTintOpacity = dbl("learnedTintOpacity", learnedTintOpacity); learnedBlurRadius = dbl("learnedBlurRadius", learnedBlurRadius)
        learnedDistortAmount = dbl("learnedDistortAmount", learnedDistortAmount)
        learnedRefractAmount = dbl("learnedRefractAmount", learnedRefractAmount)
        learnedRefractHeight = dbl("learnedRefractHeight", learnedRefractHeight); learnedAberration = dbl("learnedAberration", learnedAberration)
        learnedShadowOpacity = dbl("learnedShadowOpacity", learnedShadowOpacity)
        learnedShadowRadius = dbl("learnedShadowRadius", learnedShadowRadius)
        learnedShadowOffsetY = dbl("learnedShadowOffsetY", learnedShadowOffsetY)
        learnedEdgeHighlight = dbl("learnedEdgeHighlight", learnedEdgeHighlight)
        learnedTextDark = bol("learnedTextDark", learnedTextDark); learnedTextShadow = dbl("learnedTextShadow", learnedTextShadow)
        loading = false
    }

    var asDictionary: [String: Any] {
        [
            "content": content.rawValue,
            "width": width, "height": height, "capsule": capsule, "cornerRadius": cornerRadius, "bottomOffset": bottomOffset,
            "iconSize": iconSize, "fontSize": fontSize, "variant": variant, "tintOpacity": tintOpacity, "blurRadius": blurRadius,
            "distortAmount": distortAmount, "refractAmount": refractAmount, "refractHeight": refractHeight, "aberration": aberration,
            "lensing": lensing, "scrim": scrim, "subdued": subdued, "interaction": interaction, "adaptive": adaptive,
            "shadowOpacity": shadowOpacity, "shadowRadius": shadowRadius, "shadowOffsetY": shadowOffsetY, "edgeHighlight": edgeHighlight,
            "textDark": textDark, "pendingAlpha": pendingAlpha, "partialAlpha": partialAlpha, "textShadow": textShadow,
            "barPillWidth": barPillWidth, "barCount": barCount, "barWidth": barWidth,
            "barGap": barGap, "barSpeed": barSpeed, "barFloor": barFloor, "barRange": barRange,
            "learnedWordSize": learnedWordSize, "learnedWordWeight": learnedWordWeight, "learnedTextWeight": learnedTextWeight,
            "learnedTextAlpha": learnedTextAlpha, "learnedCaptionSize": learnedCaptionSize, "learnedCaptionAlpha": learnedCaptionAlpha,
            "learnedSepAlpha": learnedSepAlpha, "learnedLineGap": learnedLineGap, "learnedCaptionGap": learnedCaptionGap,
            "learnedPadX": learnedPadX, "learnedPadY": learnedPadY, "learnedRadius": learnedRadius,
            "learnedOwnGlass": learnedOwnGlass, "learnedVariant": learnedVariant, "learnedTintOpacity": learnedTintOpacity,
            "learnedBlurRadius": learnedBlurRadius, "learnedDistortAmount": learnedDistortAmount,
            "learnedRefractAmount": learnedRefractAmount, "learnedRefractHeight": learnedRefractHeight,
            "learnedAberration": learnedAberration, "learnedShadowOpacity": learnedShadowOpacity,
            "learnedShadowRadius": learnedShadowRadius, "learnedShadowOffsetY": learnedShadowOffsetY,
            "learnedEdgeHighlight": learnedEdgeHighlight, "learnedTextDark": learnedTextDark, "learnedTextShadow": learnedTextShadow,
        ]
    }

    private func save() {
        guard !loading else { return }
        let d = UserDefaults.standard
        for (k, v) in asDictionary { d.set(v, forKey: Self.prefix + k) }
    }

    /// 只给 --preview-hud --wave 用：这次进程按波形画，但不动用户存着的选择
    func previewAsWaveform() {
        loading = true
        content = .waveform
        loading = false
    }
}
