import Foundation

/// 一次按住说话用的识别引擎。QwenASR（DashScope）和 CartesiaASR 都长这样，
/// AppDelegate / SelfTest 只认这个面：connect → send(PCM 16k s16) → finish → 回调全文。
protocol ASREngine: AnyObject {
    var onPartial: ((String) -> Void)? { get set }     // 进行中那句的文本，主线程
    var onSentence: ((String) -> Void)? { get set }    // 一句定稿，主线程
    var onError: ((String) -> Void)? { get set }       // 主线程
    func connect()
    func send(_ pcm: Data)
    func finish(timeout: TimeInterval, completion: @escaping (String) -> Void)
    func cancel()
}

/// 识别模型清单：
///   "qwen"   → 千问 qwen-audio-3.0（DashScope，Config.asrModel 可换具体型号），中文 / 中英混说
///   "cartesia" → Cartesia ink-2（官方 API），英文
struct ASRModel: Equatable {
    let id: String
    let title: String
    let note: String    // 选项右侧的小字：用户选之前需要知道的限制

    static var presets: [ASRModel] { [
        ASRModel(id: "qwen", title: "Qwen ASR Flash", note: ""),
        ASRModel(id: "cartesia", title: "Cartesia Ink-2", note: "English only"),
    ] }

    static func find(_ id: String) -> ASRModel {
        presets.first { $0.id == id } ?? presets[0]
    }

    var keyMissing: Bool {
        id == "cartesia" ? Config.shared.cartesiaKey.isEmpty : Config.shared.apiKey.isEmpty
    }

    /// 按当前配置造一个引擎。key 缺失时返回 nil（调用方提示）。
    static func makeEngine(_ model: ASRModel) -> ASREngine? {
        guard !model.keyMissing else { return nil }
        let cfg = Config.shared
        if model.id == "cartesia" {
            return CartesiaASR(apiKey: cfg.cartesiaKey, keyterms: cfg.vocabulary.keys.sorted())
        }
        return QwenASR(apiKey: cfg.apiKey, model: cfg.asrModel, vocabulary: cfg.vocabulary, maxSilence: cfg.maxSentenceSilence)
    }
}
