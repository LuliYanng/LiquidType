import AVFoundation
import Foundation

/// 麦克风采集 → 单声道 → 16k/16bit PCM 块。
/// tap 用 format:nil 拿节点真实格式，
/// 拿到第一块真实数据后再建转换器（按报告格式装 tap 会被 CoreAudio 静默掐死）。
///
/// AVAudioEngine 会把输入设备和格式缓存在自己的图里：插拔显示器、睡眠唤醒、换默认设备之后，
/// 老引擎再 start() 就一直 -10868（kAudioUnitErr_FormatNotSupported），或者 start() 成功
/// 却一块数据都不来 —— 而且不会自己恢复，只能重启 App。所以：
/// - 每次开麦都换一台全新的引擎，不跨会话复用；
/// - 起不来就重建再试一次；
/// - 起来之后盯着第一块数据，迟迟不来就重建；还是不来就报给用户，别让人以为是识别不准。
final class AudioCapture {
    static let targetRate: Double = 16000

    private var engine: AVAudioEngine?
    private let queue = DispatchQueue(label: "liquidtype.audio")
    private var converter: AVAudioConverter?
    private var tapFormat: AVAudioFormat?
    private var active = false
    private var sawAudio = false
    private var generation = 0
    private var configObserver: NSObjectProtocol?
    private var onLevel: ((Float) -> Void)?
    private var onChunk: ((Data) -> Void)?
    private var onError: ((String) -> Void)?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: AudioCapture.targetRate, channels: 1, interleaved: true
    )!

    /// 第一块数据最晚该来的时间；本地麦克风正常时 20~50ms 就到了
    private static let firstChunkTimeout: TimeInterval = 0.9

    static func requestPermission(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { completion(ok) } }
        default: completion(false)
        }
    }

    /// onLevel / onError 主线程；onChunk 音频线程。onLevel 给原始 RMS（0..1），约 20ms 一次
    func start(
        onLevel: @escaping (Float) -> Void,
        onChunk: @escaping (Data) -> Void,
        onError: @escaping (String) -> Void = { _ in }
    ) {
        queue.async {
            guard !self.active else { return }
            self.onLevel = onLevel
            self.onChunk = onChunk
            self.onError = onError
            self.active = true
            self.generation &+= 1
            guard self.bringUpEngine() || self.bringUpEngine() else {
                self.active = false
                self.clearCallbacks()
                DispatchQueue.main.async { onError(HUDCopy.micUnreachable) }
                return
            }
            self.armWatchdog(retryLeft: 1)
        }
    }

    func stop() {
        queue.async {
            guard self.active else { return }
            self.active = false
            self.generation &+= 1
            self.teardownEngine()
            self.clearCallbacks()
        }
    }

    // MARK: - 引擎

    /// 建一台新引擎、装 tap、跑起来。失败返回 false（已清干净，可以直接再调一次）。
    private func bringUpEngine() -> Bool {
        teardownEngine()
        converter = nil
        tapFormat = nil
        sawAudio = false

        let engine = AVAudioEngine()
        self.engine = engine
        // 会话进行中设备变了（插耳机、拔显示器）：CoreAudio 只通知一次，收到就整台重建
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                guard self.active, self.engine === engine else { return }
                Log.write("Audio config changed mid-session, rebuilding engine")
                if self.bringUpEngine() { self.armWatchdog(retryLeft: 1) }
            }
        }
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let self, self.active, buffer.frameLength > 0 else { return }
            self.sawAudio = true
            if self.tapFormat != buffer.format {
                self.tapFormat = buffer.format
                self.converter = nil
                let f = buffer.format
                Log.write("Mic format: \(Int(f.sampleRate))Hz ch=\(f.channelCount) interleaved=\(f.isInterleaved)")
            }
            guard let mono = self.channel0Mono(from: buffer) else { return }
            if let onLevel = self.onLevel { self.emitLevels(mono, onLevel) }
            if self.converter == nil {
                self.converter = AVAudioConverter(from: mono.format, to: self.targetFormat)
            }
            if let chunk = self.resample(mono) { self.onChunk?(chunk) }
        }
        do {
            engine.prepare()
            try engine.start()
            return true
        } catch {
            Log.write("AudioEngine start failed: \(error)")
            teardownEngine()
            return false
        }
    }

    private func teardownEngine() {
        if let token = configObserver {
            NotificationCenter.default.removeObserver(token)
            configObserver = nil
        }
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        self.engine = nil
    }

    /// start() 成功不代表数据会来：链路可能被 CoreAudio 静默掐死。
    /// 超时还没见到第一块就重建，再不行就明说。
    private func armWatchdog(retryLeft: Int) {
        let gen = generation
        queue.asyncAfter(deadline: .now() + AudioCapture.firstChunkTimeout) { [weak self] in
            guard let self, self.active, self.generation == gen, !self.sawAudio else { return }
            guard retryLeft > 0 else {
                Log.write("Mic delivered no audio, giving up")
                let onError = self.onError
                self.active = false
                self.teardownEngine()
                self.clearCallbacks()
                DispatchQueue.main.async { onError?(HUDCopy.micSilent) }
                return
            }
            Log.write("Mic silent \(Int(AudioCapture.firstChunkTimeout * 1000))ms after start, rebuilding engine")
            if self.bringUpEngine() {
                self.armWatchdog(retryLeft: retryLeft - 1)
            } else {
                let onError = self.onError
                self.active = false
                self.clearCallbacks()
                DispatchQueue.main.async { onError?(HUDCopy.micUnreachable) }
            }
        }
    }

    private func clearCallbacks() {
        onLevel = nil
        onChunk = nil
        onError = nil
    }

    // MARK: - 格式转换

    private func channel0Mono(from buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let chans = buffer.floatChannelData else { return nil }
        let n = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        if channelCount == 1 && !buffer.format.isInterleaved { return buffer }
        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate, channels: 1, interleaved: false
        ), let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(n)) else { return nil }
        mono.frameLength = AVAudioFrameCount(n)
        let out = mono.floatChannelData![0]
        let data = chans[0]
        if buffer.format.isInterleaved {
            for i in 0..<n { out[i] = data[i * channelCount] }
        } else {
            for i in 0..<n { out[i] = data[i] }
        }
        return mono
    }

    /// macOS 的 tap 不一定按 bufferSize 给，一块可能就是 100ms；整块算一个 RMS，波形会一顿一顿地跳。
    /// 切成 20ms 小窗各算一个，按它们在块里的时间错开发到主线程。
    private func emitLevels(_ mono: AVAudioPCMBuffer, _ onLevel: @escaping (Float) -> Void) {
        guard let data = mono.floatChannelData?[0] else { return }
        let n = Int(mono.frameLength)
        let rate = mono.format.sampleRate
        let window = max(1, Int(rate * 0.02))
        var start = 0
        while start < n {
            var end = min(n, start + window)
            if n - end < window / 2 { end = n }   // 剩个零头就并进这一窗，几十个采样算出来的 RMS 抖得厉害
            var sum: Float = 0
            for i in start..<end { sum += data[i] * data[i] }
            let rms = sqrt(sum / Float(end - start))
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(start) / rate) { onLevel(rms) }
            start = end
        }
    }

    private func resample(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let converter else { return nil }
        let ratio = AudioCapture.targetRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }
        var error: NSError?
        var consumed = false
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return nil }
        return Data(bytes: ch[0], count: Int(out.frameLength) * MemoryLayout<Int16>.size)
    }
}
