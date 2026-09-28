import Foundation

/// Beta fast path: asks TypeSafe's Jev whether a transcript can be typed as-is, racing the polish request.
/// Short, clean utterances then skip the ~1s polish wait. Jev answers in ~300ms on a warm connection,
/// but a cold TLS handshake can take seconds, so the connection is kept warm like the polisher's.
enum JevGate {
    static var enabled: Bool { Config.shared.jevEnabled && !Config.shared.jevKey.isEmpty }

    private static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    private static var keepWarmTimer: Timer?
    private static var lastWarm = Date.distantPast

    /// Same question the offline eval was calibrated on (2026-09-25, threshold 0.5–0.6)
    private static let question: [String: Any] = [
        "type": "noul",
        "instructions": "This is a raw speech-to-text transcript that a user dictated and is about to send exactly as-is. "
            + "Is it already clean and correct, so that it can be sent without any editing?",
        "criteria": [
            "true": "Reads naturally and says what the speaker clearly meant; punctuation is fine; no filler words, "
                + "no repeated or restarted words, no spoken self-corrections, no misrecognized words.",
            "false": "Contains filler words (嗯/呃/啊/um/uh), repeats or restarts, a spoken self-correction "
                + "(不对/我是说/actually/wait), words that look misrecognized (homophones, garbled or nonsensical phrases), "
                + "or broken punctuation.",
        ],
    ]

    /// Probability (0–1) that `raw` needs no editing, or nil on any failure. Completion runs on main.
    static func check(_ raw: String, completion: @escaping (Double?) -> Void) {
        let key = Config.shared.jevKey
        guard !key.isEmpty else { completion(nil); return }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 5
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["state": raw, "model": "jev-latest", "questions": ["ready": question]]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { data, resp, err in
            var score: Double?
            if let data,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let answers = obj["answers"] as? [String: Any],
               let ready = answers["ready"] as? [String: Any] {
                score = (ready["noul"] as? NSNumber)?.doubleValue
            }
            if score == nil {
                let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
                let bodyText = data.flatMap { String(data: $0, encoding: .utf8) }?.prefix(200) ?? ""
                Log.write("Jev failed (http \(status)): \(err?.localizedDescription ?? "") \(bodyText)")
            }
            DispatchQueue.main.async { completion(score) }
        }.resume()
    }

    /// Keeps the TLS connection hot for the life of the app. /v1/models is free and also validates the key.
    static func startKeepWarm() {
        keepWarmTimer?.invalidate()
        guard enabled else { return }
        warm()
        keepWarmTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in warm(force: true) }
    }

    /// Also called on key press as a fallback (e.g. after the Mac wakes from sleep)
    static func warm(force: Bool = true) {
        let key = Config.shared.jevKey
        guard enabled else { return }
        guard force || Date().timeIntervalSince(lastWarm) > 20 else { return }
        lastWarm = Date()
        var req = URLRequest(url: URL(string: "https://api.typesafe.ai/v1/models")!)
        req.timeoutInterval = 15
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let t0 = Date()
        URLSession.shared.dataTask(with: req) { _, resp, err in
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            Log.write("Warm jev: http \(status) in \(ms)ms \(err?.localizedDescription ?? "")")
        }.resume()
    }
}
