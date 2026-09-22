import CoreAudio
import Foundation

/// 听写时把系统外放静音：看视频/听歌时按住说话，扬声器的声音会被麦克风收回去，
/// 识别里就混进视频里的人声。开始听 → 静音，结束 → 还原。
///
/// 规矩：
/// - 只在输出设备确实被某个进程占着（正在出声）时才动手，安静时一点不碰；
/// - 记住动手前的状态，只还原自己改过的那台设备；用户自己已经静音的，结束时不会被"帮忙"打开；
/// - 设备不支持 mute 属性（不少 USB / 蓝牙声卡如此）时退回把音量拧到 0，结束再拧回去。
enum SystemAudio {
    private struct Change {
        let device: AudioDeviceID
        let usedMute: Bool          // true = 改的 mute 开关；false = 改的音量
        let volumeElement: AudioObjectPropertyElement
        let previousVolume: Float32 // usedMute == false 时有意义
    }

    private static var change: Change?
    private static let lock = NSLock()

    /// 正在出声就静音。返回是否真的动了手。
    @discardableResult
    static func muteIfPlaying() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard change == nil, let dev = defaultOutputDevice() else { return false }
        guard isRunningSomewhere(dev) else { return false }

        if let muted = getMute(dev) {
            if muted { return false }               // 用户自己已经静音了，别碰
            guard setMute(dev, true) else { return false }
            change = Change(device: dev, usedMute: true, volumeElement: 0, previousVolume: 0)
            Log.write("Muted system output (device \(dev)) while listening")
            return true
        }
        // 没有 mute 属性：拧音量
        guard let vol = getVolume(dev) else { return false }
        guard vol.value > 0.001, setVolume(dev, element: vol.element, 0) else { return false }
        change = Change(device: dev, usedMute: false, volumeElement: vol.element, previousVolume: vol.value)
        Log.write("Muted system output by volume (device \(dev), was \(vol.value)) while listening")
        return true
    }

    /// 还原成静音之前的样子；没静过音就是空操作。
    static func restore() {
        lock.lock()
        defer { lock.unlock() }
        guard let c = change else { return }
        change = nil
        if c.usedMute {
            _ = setMute(c.device, false)
        } else {
            _ = setVolume(c.device, element: c.volumeElement, c.previousVolume)
        }
        Log.write("Restored system output (device \(c.device))")
    }

    // MARK: - CoreAudio 小工具

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dev = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
        return st == noErr && dev != AudioDeviceID(kAudioObjectUnknown) ? dev : nil
    }

    /// 有进程正在往这台设备上放音频（视频、音乐、系统提示音都算）
    private static func isRunningSomewhere(_ dev: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let st = AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &running)
        return st == noErr && running != 0
    }

    private static func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func getMute(_ dev: AudioDeviceID) -> Bool? {
        var addr = muteAddress()
        guard AudioObjectHasProperty(dev, &addr) else { return nil }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(dev, &addr, &settable) == noErr, settable.boolValue else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    private static func setMute(_ dev: AudioDeviceID, _ on: Bool) -> Bool {
        var addr = muteAddress()
        var value: UInt32 = on ? 1 : 0
        let st = AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        if st != noErr { Log.write("setMute failed: \(st)") }
        return st == noErr
    }

    /// 主音量；有的设备主元素没有音量，退回到第一个能读能写的声道
    private static let volumeElements: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain, 1, 2]

    private static func volumeAddress(_ el: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: el
        )
    }

    private static func getVolume(_ dev: AudioDeviceID) -> (element: AudioObjectPropertyElement, value: Float32)? {
        for el in volumeElements {
            var addr = volumeAddress(el)
            guard AudioObjectHasProperty(dev, &addr) else { continue }
            var settable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(dev, &addr, &settable) == noErr, settable.boolValue else { continue }
            var v: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr else { continue }
            return (el, v)
        }
        return nil
    }

    @discardableResult
    private static func setVolume(_ dev: AudioDeviceID, element: AudioObjectPropertyElement, _ value: Float32) -> Bool {
        var addr = volumeAddress(element)
        var v = value
        let st = AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        if st != noErr { Log.write("setVolume failed: \(st)") }
        return st == noErr
    }
}
