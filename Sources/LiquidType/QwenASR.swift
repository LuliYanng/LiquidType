import Foundation

/// 千问流式识别（qwen-audio-3.0-asr-flash-streaming，DashScope inference WebSocket 协议）。
/// 协议：
///   run-task → task-started → 二进制 PCM → result-generated* → finish-task → task-finished
/// 一次按住说话 = 一个 task。task-started 之前发音频会被 1007 踢，所以先攒着。
final class QwenASR: NSObject, URLSessionWebSocketDelegate, ASREngine {
    var onPartial: ((String) -> Void)?       // 当前进行中那句的文本，主线程
    var onSentence: ((String) -> Void)?      // 一句定稿（sentence_end），主线程；按顺序
    var onSentenceMeta: ((String, Int?) -> Void)?   // 同上，附带服务端 end_time(ms)，自测量延迟用
    var onError: ((String) -> Void)?         // 主线程

    private let apiKey: String
    private let model: String
    private let vocabulary: [String: Int]
    private let maxSilence: Int
    private let taskId = UUID().uuidString.replacingOccurrences(of: "-", with: "")

    private var session: URLSession!
    private var ws: URLSessionWebSocketTask?
    private let lock = NSLock()
    private var started = false
    private var closed = false
    private var pending: [Data] = []
    private var finals: [String] = []
    private var current = ""
    private var finishCompletion: ((String) -> Void)?
    private var finishTimer: DispatchWorkItem?
    private var connectedAt = Date()
    private var region = DashScopeRegion.beijing

    init(apiKey: String, model: String, vocabulary: [String: Int], maxSilence: Int) {
        self.apiKey = apiKey
        self.model = model
        self.vocabulary = vocabulary
        self.maxSilence = maxSilence
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    var fullText: String {
        lock.lock(); defer { lock.unlock() }
        return (finals + [current]).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 先认 key 在哪个地域（认过的同步返回，不耽误），再连。认的这段时间说的话照样攒在 pending 里
    func connect() {
        connectedAt = Date()
        DashScope.resolve { [weak self] region in self?.open(region) }
    }

    private func open(_ region: DashScopeRegion) {
        var req = URLRequest(url: region.inferenceSocket)
        req.setValue("bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: req)
        lock.lock()
        if closed { lock.unlock(); return }   // 还没认完就已经松键 / 取消了
        self.region = region
        ws = task
        lock.unlock()
        task.resume()

        var params: [String: Any] = [
            "sample_rate": Int(AudioCapture.targetRate),
            "format": "pcm",
            "max_sentence_silence": maxSilence,
        ]
        if !vocabulary.isEmpty { params["vocabulary"] = vocabulary }
        let msg: [String: Any] = [
            "header": ["action": "run-task", "task_id": taskId, "streaming": "duplex"],
            "payload": [
                "task_group": "audio", "task": "asr", "function": "recognition",
                "model": model, "parameters": params, "input": [:],
            ],
        ]
        sendJSON(msg)
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

    /// 松键：让服务端 flush 尾巴，等 task-finished（有界）。尾句若没被服务端定稿，
    /// 这里补发一次 onSentence，然后回调全文。
    func finish(timeout: TimeInterval = 3.0, completion: @escaping (String) -> Void) {
        lock.lock()
        finishCompletion = completion
        let s = started
        lock.unlock()
        if s {
            sendJSON([
                "header": ["action": "finish-task", "task_id": taskId, "streaming": "duplex"],
                "payload": ["input": [:]],
            ])
        }
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
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { finals.append(tail) }
        current = ""
        lock.unlock()
        finishTimer?.cancel()
        let text = fullText
        ws?.cancel(with: .normalClosure, reason: nil)
        ws = nil
        DispatchQueue.main.async {
            if !tail.isEmpty { self.onSentence?(tail) }
            cb(text)
        }
    }

    private func fail(_ msg: String) {
        Log.write("ASR error: \(msg)")
        DispatchQueue.main.async { self.onError?(msg) }
        complete()
    }

    private func sendJSON(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: data, encoding: .utf8) else { return }
        ws?.send(.string(str)) { [weak self] err in
            if let err { self?.fail("send json: \(err.localizedDescription)") }
        }
    }

    private func receiveLoop() {
        guard let task = ws else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                self.lock.lock(); let c = self.closed; self.lock.unlock()
                guard !c else { return }
                // 握手就被拒：key 不是这个地域的（或失效了），忘掉记住的地域，下次重新认
                let status = (task.response as? HTTPURLResponse)?.statusCode
                if status == 401 || status == 403 { DashScope.forget() }
                let http = status.map { "http \($0) " } ?? ""
                self.fail("recv: \(http)\(self.region.host): \(err.localizedDescription)")
            case .success(let message):
                if case .string(let text) = message { self.handle(text) }
                self.receiveLoop()
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let header = obj["header"] as? [String: Any] else { return }
        let event = header["event"] as? String ?? ""
        switch event {
        case "task-started":
            Log.write("ASR task started in \(Int(Date().timeIntervalSince(connectedAt) * 1000))ms")
            lock.lock()
            started = true
            let queued = pending
            pending = []
            lock.unlock()
            for chunk in queued { send(chunk) }
        case "result-generated":
            let sentence = ((obj["payload"] as? [String: Any])?["output"] as? [String: Any])?["sentence"] as? [String: Any] ?? [:]
            let t = (sentence["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let end = sentence["sentence_end"] as? Bool ?? false
            lock.lock()
            if end {
                if !t.isEmpty { finals.append(t) }
                current = ""
            } else {
                current = t
            }
            lock.unlock()
            let endTime = sentence["end_time"] as? Int
            DispatchQueue.main.async {
                if end {
                    if !t.isEmpty { self.onSentence?(t); self.onSentenceMeta?(t, endTime) }
                    self.onPartial?("")
                } else {
                    self.onPartial?(t)
                }
            }
        case "task-finished":
            Log.write("ASR task finished")
            complete()
        case "task-failed":
            if (header["error_code"] as? String) == "InvalidApiKey" { DashScope.forget() }
            fail("\(header["error_code"] ?? ""): \(header["error_message"] ?? "")")
        default:
            break
        }
    }
}
