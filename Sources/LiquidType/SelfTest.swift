import Foundation

/// `LiquidType --test-asr file.wav`：不开麦不粘贴，把 wav 流给识别引擎（VT_ASR 选，默认千问）→ 打印 raw → 润色 → 打印结果。
/// 用来在没有 TCC 权限的环境里验证识别 + 润色链路。
enum SelfTest {
    static func run(wavPath: String) -> Never {
        let pcm = loadPCM16k(path: wavPath)
        let cfg = Config.shared
        let model = ASRModel.find(cfg.asrChoice)
        print("[test] \(pcm.count / 32) ms of audio, asr=\(model.id) polish=\(cfg.polishModel)")
        // 先把连接握热，再握第二次看是否复用（应从 ~5s 降到 ~0.3s），然后才开始识别
        let gate = DispatchSemaphore(value: 0)
        Polisher.warm(force: true) { Polisher.warm(force: true) { gate.signal() } }
        DispatchQueue.global().async { gate.wait() }
        _ = gate.wait(timeout: .now() + 20)
        guard let asr = ASRModel.makeEngine(model) else { print("no API key for \(model.id)"); exit(2) }
        asr.onPartial = { t in if !t.isEmpty { print("[partial] \(t)") } }
        var audioSentMs = 0
        let realtime = ProcessInfo.processInfo.environment["VT_TEST_REALTIME"] == "1"
        asr.onSentence = { t in print("[sentence] \(t)") }
        (asr as? QwenASR)?.onSentenceMeta = { t, endTime in
            if let endTime, realtime { print("[final-latency] \(audioSentMs - endTime)ms after this sentence's audio ended (end_time=\(endTime))") }
        }
        asr.onError = { e in print("[error] \(e)"); exit(1) }
        asr.connect()
        let chunk = 3200 // 100ms @16k s16
        let t0 = Date()
        DispatchQueue.global().async {
            var off = 0
            while off < pcm.count {
                let end = min(off + chunk, pcm.count)
                asr.send(pcm.subdata(in: off..<end))
                off = end
                audioSentMs = off / 32
                usleep(realtime ? 100_000 : 25_000) // VT_TEST_REALTIME=1 按真实速度，否则 4x
            }
            let sentAt = Date()
            asr.finish(timeout: 3.0) { raw in
                print("[raw] (\(Int(Date().timeIntervalSince(sentAt) * 1000))ms after last byte, \(Int(Date().timeIntervalSince(t0) * 1000))ms total) \(raw)")
                guard !raw.isEmpty else { exit(1) }
                Polisher.polish(raw, style: AppStyle.generic, appName: "备忘录") { text, ok in
                    print("[polished ok=\(ok)] \(text)")
                    exit(0)
                }
            }
        }
        RunLoop.main.run()
        exit(0)
    }

    private static func loadPCM16k(path: String) -> Data {
        // 用 macOS 自带 afconvert 统一转成 16k/mono/s16 wav，再剥 44 字节头
        let tmp = NSTemporaryDirectory() + "vt-\(UUID().uuidString).wav"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        p.arguments = ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", path, tmp]
        try? p.run()
        p.waitUntilExit()
        guard let data = FileManager.default.contents(atPath: tmp), data.count > 44 else {
            print("cannot read \(path)"); exit(2)
        }
        return data.subdata(in: 44..<data.count)
    }
}
