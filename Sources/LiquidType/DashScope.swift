import CryptoKit
import Foundation

/// 百炼（DashScope）按地域部署：北京、新加坡（国际站）、美国弗吉尼亚各有各的域名，
/// key 只在创建它的那个地域能用，拿去调别的地域一律 401——国际站的 key 连北京，就是一直「连接断了」。
enum DashScopeRegion: String, CaseIterable {
    case beijing, singapore, virginia

    var host: String {
        switch self {
        case .beijing: return "dashscope.aliyuncs.com"
        case .singapore: return "dashscope-intl.aliyuncs.com"
        case .virginia: return "dashscope-us.aliyuncs.com"
        }
    }

    /// 实时识别（WebSocket）
    var inferenceSocket: URL { URL(string: "wss://\(host)/api-ws/v1/inference")! }

    /// OpenAI 兼容接口（润色、预热）
    func compatible(_ path: String) -> URL { URL(string: "https://\(host)/compatible-mode/v1/\(path)")! }
}

/// 不让用户选地域：第一次用某把 key 时三个地域同时问一遍，谁认这把 key 就记住谁。
/// 记的是 key 的指纹（哈希前 16 位，不存明文），换了 key 自然重新认。
enum DashScope {
    private static let d = UserDefaults.standard
    private static let lock = NSLock()
    private static var waiters: [String: [(DashScopeRegion) -> Void]] = [:]   // key 指纹 → 等结果的；有这项 = 正在探测

    /// 当前 key 所在的地域。还没认出来（或没联网认失败）先按北京——之前一直写死的就是北京
    static var region: DashScopeRegion { known(fingerprint(Config.shared.apiKey)) ?? .beijing }

    /// 要连之前确定地域：认过的直接回调（同步），没认过的先探测再回调（在 URLSession 的线程上）
    static func resolve(_ completion: @escaping (DashScopeRegion) -> Void) {
        let key = Config.shared.apiKey
        guard !key.isEmpty else { completion(.beijing); return }
        let fp = fingerprint(key)
        if let r = known(fp) { completion(r); return }
        lock.lock()
        let probing = waiters[fp] != nil
        waiters[fp, default: []].append(completion)
        lock.unlock()
        if !probing { probe(key: key, fp: fp) }
    }

    /// 连接被拒（401/403）：记住的地域不对了或者 key 失效了，下次用的时候重新认
    static func forget() {
        d.removeObject(forKey: "dashscopeRegion")
        d.removeObject(forKey: "dashscopeRegionKey")
    }

    private static func known(_ fp: String) -> DashScopeRegion? {
        guard d.string(forKey: "dashscopeRegionKey") == fp else { return nil }
        return DashScopeRegion(rawValue: d.string(forKey: "dashscopeRegion") ?? "")
    }

    private static func fingerprint(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// 每个地域 GET 一次 /models：2xx 的那个就是。第一个 2xx 回来就定，不等其他的；
    /// 走 URLSession.shared，认出来的这条 TLS 连接顺手留给润色用
    private static func probe(key: String, fp: String) {
        let t0 = Date()
        let resultLock = NSLock()
        var results: [(DashScopeRegion, Int?)] = []   // 按返回先后；nil = 网络错误 / 超时
        var settled = false
        for r in DashScopeRegion.allCases {
            var req = URLRequest(url: r.compatible("models"))
            req.timeoutInterval = 6
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            URLSession.shared.dataTask(with: req) { _, resp, _ in
                let status = (resp as? HTTPURLResponse)?.statusCode
                resultLock.lock()
                guard !settled else { resultLock.unlock(); return }
                results.append((r, status))
                let hit = status.map { (200..<300).contains($0) } ?? false
                settled = hit || results.count == DashScopeRegion.allCases.count
                let snapshot = results, done = settled
                resultLock.unlock()
                if done { settle(snapshot, fp: fp, ms: Int(Date().timeIntervalSince(t0) * 1000)) }
            }.resume()
        }
    }

    private static func settle(_ results: [(DashScopeRegion, Int?)], fp: String, ms: Int) {
        let summary = results.map { "\($0.0.rawValue)=\($0.1.map { String($0) } ?? "unreachable")" }.joined(separator: " ")
        let region: DashScopeRegion
        if let hit = results.first(where: { ($0.1 ?? 0) / 100 == 2 }) {
            region = hit.0
            d.set(region.rawValue, forKey: "dashscopeRegion")
            d.set(fp, forKey: "dashscopeRegionKey")
            Log.write("DashScope region: \(region.rawValue) in \(ms)ms (\(summary))")
        } else if results.allSatisfy({ $0.1 == 401 || $0.1 == 403 }) {
            region = .beijing
            Log.write("DashScope key rejected by every region — wrong or revoked key? (\(summary))")
        } else {
            // 没有一个明确认的：有哪个地域回了 401/403 以外的 HTTP 状态就先用它（不记，下次再认），否则北京
            region = results.first(where: { $0.1 != nil && $0.1 != 401 && $0.1 != 403 })?.0 ?? .beijing
            Log.write("DashScope region unsure, using \(region.rawValue) for now (\(summary))")
        }
        lock.lock()
        let callbacks = waiters.removeValue(forKey: fp) ?? []
        lock.unlock()
        callbacks.forEach { $0(region) }
    }
}
