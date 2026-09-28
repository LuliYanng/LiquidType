import Foundation

/// 按住说话的键。用 flagsChanged 的 keyCode 区分左右。
enum HotkeyChoice: String, CaseIterable {
    case rightOption, rightCommand, rightControl, fn

    var title: String {
        switch self {
        case .rightOption: return "Right Option (⌥)"
        case .rightCommand: return "Right Command (⌘)"
        case .rightControl: return "Right Control (⌃)"
        case .fn: return "fn / 🌐"
        }
    }

    var keyCode: UInt16 {
        switch self {
        case .rightOption: return 61
        case .rightCommand: return 54
        case .rightControl: return 62
        case .fn: return 63
        }
    }
}

/// 配置来源（优先级从高到低）：UserDefaults（菜单里改的）→ ~/.liquidtype.env → 进程环境变量。
final class Config {
    static let shared = Config()

    private let d = UserDefaults.standard
    private var envFile: [String: String] = [:]

    private init() {
        envFile = Self.loadEnvFile()
    }

    private static func loadEnvFile() -> [String: String] {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".liquidtype.env")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let k = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var v = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2 { v = String(v.dropFirst().dropLast()) }
            out[k] = v
        }
        return out
    }

    private func env(_ key: String) -> String? {
        if let v = envFile[key], !v.isEmpty { return v }
        if let v = ProcessInfo.processInfo.environment[key], !v.isEmpty { return v }
        return nil
    }

    // MARK: - 键

    var apiKey: String {
        get {
            if let v = d.string(forKey: "dashscopeApiKey"), !v.isEmpty { return v }
            return env("DASHSCOPE_API_KEY") ?? ""
        }
        set { d.set(newValue, forKey: "dashscopeApiKey") }
    }

    /// 说话键，默认 fn（菜单里不给选；`defaults write app.liquidtype.mac hotkey rightOption` 可改）
    var hotkey: HotkeyChoice {
        get { HotkeyChoice(rawValue: d.string(forKey: "hotkey") ?? "") ?? .fn }
        set { d.set(newValue.rawValue, forKey: "hotkey") }
    }

    /// 触发方式：true = 按一下开始、再按一下结束（默认）；false = 按住说话、松开结束（`defaults write … toggleMode 0`）
    var toggleMode: Bool {
        get { d.object(forKey: "toggleMode") == nil ? true : d.bool(forKey: "toggleMode") }
        set { d.set(newValue, forKey: "toggleMode") }
    }

    var polishEnabled: Bool {
        get { d.object(forKey: "polishEnabled") == nil ? true : d.bool(forKey: "polishEnabled") }
        set { d.set(newValue, forKey: "polishEnabled") }
    }

    /// 写入方式：false = Unicode 键盘事件逐字打（默认，不碰剪贴板）；true = ⌘V 粘贴
    var usePaste: Bool {
        get { d.bool(forKey: "usePaste") }
        set { d.set(newValue, forKey: "usePaste") }
    }

    /// 听写时把系统外放静音（默认开）：正在放视频/音乐时按住说话，扬声器的声音不会被麦克风收进去
    var muteWhileListening: Bool {
        get { d.object(forKey: "muteWhileListening") == nil ? true : d.bool(forKey: "muteWhileListening") }
        set { d.set(newValue, forKey: "muteWhileListening") }
    }

    /// 千问的具体型号（asrChoice == "qwen" 时用）
    var asrModel: String { env("VT_ASR_MODEL") ?? "qwen-audio-3.0-asr-flash-streaming" }

    /// 识别引擎：菜单里选的优先，其次 ~/.liquidtype.env 的 VT_ASR（"qwen" 或 "cartesia"），默认千问
    var asrChoice: String {
        get {
            if let v = d.string(forKey: "asrChoice"), !v.isEmpty { return v }
            return env("VT_ASR") ?? "qwen"
        }
        set { d.set(newValue, forKey: "asrChoice") }
    }

    /// Cartesia（cartesia.ai）的 key，识别模型选 Cartesia 时必填
    var cartesiaKey: String {
        get {
            if let v = d.string(forKey: "cartesiaApiKey"), !v.isEmpty { return v }
            return env("CARTESIA_API_KEY") ?? ""
        }
        set { d.set(newValue, forKey: "cartesiaApiKey") }
    }

    var openrouterKey: String {
        get {
            if let v = d.string(forKey: "openrouterApiKey"), !v.isEmpty { return v }
            return env("OPENROUTER_API_KEY") ?? ""
        }
        set { d.set(newValue, forKey: "openrouterApiKey") }
    }

    /// 润色 LLM。菜单里选的优先，其次 ~/.liquidtype.env 的 VT_POLISH_MODEL；认不出的一律回默认。
    /// 默认是 Claude Haiku 4.5（最忠实原话）；没填 OpenRouter key 时退到千问 3.7 Flash，只填 DashScope 一把 key 也能用
    var polishModel: String {
        get {
            let id = d.string(forKey: "polishModel").flatMap { $0.isEmpty ? nil : $0 } ?? env("VT_POLISH_MODEL") ?? ""
            if PolishModel.presets.contains(where: { $0.id == id }) { return id }
            return PolishModel.presets[openrouterKey.isEmpty ? 1 : 0].id
        }
        set { d.set(newValue, forKey: "polishModel") }
    }

    /// 断句静音阈值 ms（服务端默认 1300 太慢）
    var maxSentenceSilence: Int { Int(env("VT_MAX_SILENCE") ?? "") ?? 400 }

    /// Learn hotwords from the user's own corrections. Off unless turned on: it reads the text field back
    /// after typing into it and sends the edited passage to the LLM
    var learnHotwords: Bool {
        get { d.object(forKey: "learnHotwords") == nil ? env("VT_LEARN_HOTWORDS") == "1" : d.bool(forKey: "learnHotwords") }
        set { d.set(newValue, forKey: "learnHotwords") }
    }

    /// Hotwords learned so far or added in the panel, oldest first
    var learnedHotwords: [String] {
        get { d.stringArray(forKey: "learnedHotwords") ?? [] }
        set { d.set(newValue, forKey: "learnedHotwords") }
    }
    static let maxLearnedHotwords = 80
    /// Qwen only really biases toward "super hotwords" (weight 50): in a 2026-09-26 test, 1–5 changed nothing
    /// while 50 fixed Pipecat and Cartesia and didn't bend similar-sounding words. It takes at most 50 of them
    static let superWeight = 50, maxSuperHotwords = 50

    /// Learned since the Dictionary row was last opened: the panel highlights them
    var newHotwords: [String] {
        get { d.stringArray(forKey: "newHotwords") ?? [] }
        set { d.set(newValue, forKey: "newHotwords") }
    }

    func removeLearnedHotword(_ word: String) {
        learnedHotwords.removeAll { $0 == word }
        newHotwords.removeAll { $0 == word }
    }

    /// Words taken back with the notice's Undo ("won't learn X"): learning skips them from then on
    var rejectedHotwords: [String] {
        get { d.stringArray(forKey: "rejectedHotwords") ?? [] }
        set { d.set(newValue, forKey: "rejectedHotwords") }
    }

    func rejectLearnedHotwords(_ words: [String]) {
        words.forEach(removeLearnedHotword)
        let lower = Set(words.map { $0.lowercased() })
        rejectedHotwords = Array((rejectedHotwords.filter { !lower.contains($0.lowercased()) } + words).suffix(200))
    }

    /// Adds the words not already in the vocabulary (case-insensitive) and returns those. The oldest
    /// learned words drop off past the cap; the ones in ~/.liquidtype.env are never touched. Learning
    /// (`byHand` false) skips words the user undid; adding one by hand clears it from that list
    func addLearnedHotwords(_ words: [String], byHand: Bool = false) -> [String] {
        let lower = Set(words.map { $0.lowercased() })
        if byHand {
            rejectedHotwords = rejectedHotwords.filter { !lower.contains($0.lowercased()) }
        }
        var known = Set(vocabulary.keys.map { $0.lowercased() })
        if !byHand { known.formUnion(rejectedHotwords.map { $0.lowercased() }) }
        var added: [String] = []
        for w in words where !known.contains(w.lowercased()) {
            known.insert(w.lowercased())
            added.append(w)
        }
        if !added.isEmpty {
            learnedHotwords = Array((learnedHotwords + added).suffix(Self.maxLearnedHotwords))
            let kept = Set(learnedHotwords)
            newHotwords = newHotwords.filter(kept.contains)
        }
        return added
    }

    /// Hotwords in priority order for engines that cap the count (Cartesia): the env file's, then learned newest first
    var hotwordList: [String] {
        var seen = Set<String>()
        return (envHotwords.keys.sorted() + learnedHotwords.reversed()).filter { seen.insert($0).inserted }
    }

    /// Everything sent to ASR: the env file's words, then learned ones newest first, all at the super weight
    /// unless the env file says otherwise. Past the cap of super hotwords, the rest drop to weight 5
    var vocabulary: [String: Int] {
        let env = envHotwords
        var out: [String: Int] = [:]
        var supers = 0
        for (word, weight) in env.sorted(by: { $0.key < $1.key }) + learnedHotwords.reversed().map({ ($0, Self.superWeight) })
        where out[word] == nil {
            let isSuper = weight == Self.superWeight && supers < Self.maxSuperHotwords
            if isSuper { supers += 1 }
            out[word] = weight == Self.superWeight && !isSuper ? 5 : weight
        }
        return out
    }

    /// Hotwords from VT_HOTWORDS in ~/.liquidtype.env: "Samantha:4, Pipecat, 千问:3". A word without a weight
    /// gets the super weight; explicit weights are 1–5 or 50
    var envHotwords: [String: Int] {
        var out: [String: Int] = [:]
        for part in (env("VT_HOTWORDS") ?? "").split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "\n" }) {
            let item = part.trimmingCharacters(in: .whitespaces)
            guard !item.isEmpty else { continue }
            let pieces = item.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            let word = pieces[0]
            let weight = pieces.count > 1 ? (Int(pieces[1]) ?? Self.superWeight) : Self.superWeight
            if !word.isEmpty { out[word] = weight == Self.superWeight ? weight : max(1, min(5, weight)) }
        }
        return out
    }
}

/// "0.1.1 (main @ 732ac9f)": the version plus the branch and commit scripts/build_app.sh stamped in
enum AppVersion {
    static var summary: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "unbundled"
        guard let build = info["LTBuild"] as? String else { return version }
        return "\(version) (\(build))"
    }
}

/// 润色 LLM 清单与路由：含 "/" 走 OpenRouter，其余走 DashScope 兼容接口。
struct PolishModel {
    enum Backend { case openrouter, dashscope }
    let id: String
    let title: String

    static var presets: [PolishModel] { [
        PolishModel(id: "anthropic/claude-haiku-4.5", title: "Claude Haiku 4.5"),
        PolishModel(id: "qwen3.7-flash", title: "Qwen3.7-Flash"),
    ] }

    static func backend(_ id: String) -> Backend { id.contains("/") ? .openrouter : .dashscope }

    static func isOpenRouter(_ id: String) -> Bool { backend(id) == .openrouter }
}
