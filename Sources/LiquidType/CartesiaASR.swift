import Foundation

/// Cartesia ink-2 流式识别（官方 /stt/websocket 手动收尾端点，英文）。
///   连上 → 二进制 PCM（100ms 一块，单条 ≤32KB）→ 文本 "finalize" → 剩余音频出稿 → flush_done
/// 一次按住说话 = 一条连接。transcript 的 text 是增量：is_final 的原样拼接（自带空格，不加不减），
/// 非 final 的是推测、整段替换。ink-2 没有句子边界事件，整次说话当一句，松键后定稿。
/// 热词走 URL 的 keyterm 参数（≤100 个、合计 ≤1200 字符），只在建连时生效。
final class CartesiaASR: NSObject, URLSessionWebSocketDelegate, ASREngine {
    var onPartial: ((String) -> Void)?       // 到目前为止的文本，主线程
    var onSentence: ((String) -> Void)?      // 整次说话定稿，主线程
    var onError: ((String) -> Void)?         // 主线程

    static let defaultModel = "ink-2"
    static let apiVersion = "2026-08-14"

    private let apiKey: String
    private let model: String
    private let keyterms: [String]

    private var session: URLSession!
    private var ws: URLSessionWebSocketTask?
    private let lock = NSLock()
    private var started = false
    private var closed = false
    private var pending: [Data] = []
    private var committed = ""               // is_final 的增量拼起来
    private var current = ""                 // 最近一条非 final 的推测
    private var finishCompletion: ((String) -> Void)?
    private var finishTimer: DispatchWorkItem?
    private var connectedAt = Date()

    init(apiKey: String, model: String = CartesiaASR.defaultModel, keyterms: [String]) {
        self.apiKey = apiKey
        self.model = model
        self.keyterms = keyterms
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    var fullText: String {
        lock.lock(); defer { lock.unlock() }
        return (committed + current).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var url: URL {
        var c = URLComponents(string: "wss://api.cartesia.ai/stt/websocket")!
        var items = [
            URLQueryItem(name: "model", value: model),
            URLQueryItem(name: "encoding", value: "pcm_s16le"),
            URLQueryItem(name: "sample_rate", value: String(Int(AudioCapture.targetRate))),
            URLQueryItem(name: "cartesia_version", value: Self.apiVersion),
        ]
        var budget = 1200
        for term in keyterms.prefix(100) where term.count <= budget {
            items.append(URLQueryItem(name: "keyterm", value: term))
            budget -= term.count
        }
        c.queryItems = items
        return c.url!
    }

    func connect() {
        connectedAt = Date()
        var req = URLRequest(url: url)
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        let task = session.webSocketTask(with: req)
        ws = task
        task.resume()
        receiveLoop()
    }

    func send(_ pcm: Data) {
        lock.lock()
        if closed { lock.unlock(); return }
        if !started {
            pending.append(pcm)
            lock.unlock()
            return
        }
        lock.unlock()
        ws?.send(.data(pcm)) { [weak self] err in
            if let err { self?.fail("send: \(err.localizedDescription)") }
        }
    }

    /// 松键：让服务端把手上的音频全部出稿，等 flush_done（有界）。还没连上就等连上再发。
    func finish(timeout: TimeInterval = 3.0, completion: @escaping (String) -> Void) {
        lock.lock()
        finishCompletion = completion
        let s = started
        lock.unlock()
        if s { sendText("finalize") }
        let work = DispatchWorkItem { [weak self] in
            Log.write("ASR finish timeout — using what we have")
            self?.complete()
        }
        finishTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
    }

    func cancel() {
        lock.lock()
        closed = true
        finishCompletion = nil
        lock.unlock()
        finishTimer?.cancel()
        ws?.cancel(with: .normalClosure, reason: nil)
        ws = nil
    }

    // MARK: - internals

    private func complete() {
        lock.lock()
        guard let cb = finishCompletion else { lock.unlock(); return }
        finishCompletion = nil
        closed = true
        lock.unlock()
        finishTimer?.cancel()
        let text = fullText
        ws?.cancel(with: .normalClosure, reason: nil)
        ws = nil
        DispatchQueue.main.async {
            if !text.isEmpty { self.onSentence?(text) }
            cb(text)
        }
    }

    private func fail(_ msg: String) {
        Log.write("ASR error: \(msg)")
        DispatchQueue.main.async { self.onError?(msg) }
        complete()
    }

    private func sendText(_ s: String) {
        ws?.send(.string(s)) { [weak self] err in
            if let err { self?.fail("send \(s): \(err.localizedDescription)") }
        }
    }

    private func receiveLoop() {
        ws?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                self.lock.lock(); let c = self.closed; self.lock.unlock()
                if !c { self.fail("recv: \(err.localizedDescription)") }
            case .success(let message):
                if case .string(let text) = message { self.handle(text) }
                self.receiveLoop()
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "transcript":
            let t = obj["text"] as? String ?? ""
            lock.lock()
            if obj["is_final"] as? Bool == true { committed += t; current = "" } else { current = t }
            let sofar = (committed + current).trimmingCharacters(in: .whitespacesAndNewlines)
            lock.unlock()
            DispatchQueue.main.async { self.onPartial?(sofar) }
        case "flush_done", "done":
            Log.write("ASR finalized in \(Int(Date().timeIntervalSince(connectedAt) * 1000))ms")
            complete()
        case "error":
            fail("\(obj["error_code"] ?? "?"): \(obj["message"] ?? "")")
        default:
            break
        }
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        Log.write("ASR connected in \(Int(Date().timeIntervalSince(connectedAt) * 1000))ms")
        lock.lock()
        started = true
        let queued = pending
        pending = []
        let finishing = finishCompletion != nil
        lock.unlock()
        for chunk in queued { send(chunk) }
        if finishing { sendText("finalize") }
    }
}
