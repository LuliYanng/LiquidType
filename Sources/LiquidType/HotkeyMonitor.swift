import AppKit
import ApplicationServices

/// 说话键有两种触发方式：
/// - 按住说话（默认）：按下立即回调 onDown（马上开麦，不丢首音）；holdDelay 内松开 = 轻点、
///   或期间夹了别的键（当普通快捷键用）→ onCancel；满 holdDelay 仍按着 → onConfirm；松开 → onUp
/// - 切换式（toggleMode）：按一下（不夹别的键）→ onToggle，由上层决定是开始还是结束
///
/// 按住一个修饰键说话（push-to-talk）。
/// - 按下立即回调 onDown（马上开麦，不丢首音）
/// - holdDelay 内松开 = 轻点，或期间夹了别的键（当普通快捷键用）→ onCancel
/// - 满 holdDelay 仍按着 → onConfirm（此时才显示 HUD）
/// - 松开 → onUp
final class HotkeyMonitor {
    var onDown: (() -> Void)?
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?
    var onUp: (() -> Void)?
    /// 录音期间按 esc
    var onEscape: (() -> Void)?
    /// 现在在录音吗？只有录音时 esc 才归我们，其余时候原样放行给前台 App
    var isListening: (() -> Bool)?
    /// 切换式：完整按一下（没夹别的键）
    var onToggle: (() -> Void)?

    var choice: HotkeyChoice
    var toggleMode = false

    private var monitors: [Any] = []
    private var escapeTap: CFMachPort?
    private var tapOwnsEscape = false
    private var swallowedEscapeDown = false
    private var pending: DispatchWorkItem?
    private var down = false
    private var confirmed = false
    private var poisoned = false
    private let holdDelay: TimeInterval = 0.15

    init(choice: HotkeyChoice) {
        self.choice = choice
    }

    @discardableResult
    static func ensureAccessibilityPermission(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func start() {
        startEscapeTap()
        let flags: (NSEvent) -> Void = { [weak self] e in self?.handleFlags(e) }
        let keyDown: (NSEvent) -> Void = { [weak self] e in self?.handleKeyDown(e) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { flags($0); return $0 }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: keyDown) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { keyDown($0); return $0 }) { monitors.append(m) }
    }

    // MARK: - esc 独占

    /// NSEvent 的全局监听只能旁听：我们收到 esc 的同时，系统照样把它发给最前面的 App
    /// （在 Claude 里按住说话，esc 取消录音的同时也把人家的生成打断了）。
    /// CGEvent tap 是主动式的：录音时收到 esc 就地吃掉，不再往下发；不在录音就原样放行。
    /// 建不起来（没有辅助功能权限）就退回旁听，esc 照样能取消，只是拦不住前台 App。
    private func startEscapeTap() {
        guard escapeTap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                return Unmanaged<HotkeyMonitor>.fromOpaque(refcon)
                    .takeUnretainedValue()
                    .handleTap(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.write("Esc event tap unavailable (Accessibility?), esc falls back to passive")
            return
        }
        escapeTap = tap
        if let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        tapOwnsEscape = true
        Log.write("Esc event tap installed")
    }

    /// 主线程（run loop source 挂在主 run loop 上）。返回 nil = 这个事件到此为止。
    private func handleTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // 系统会在 tap 超时或用户输入过密时把它掐掉，掐了就重新打开
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let escapeTap { CGEvent.tapEnable(tap: escapeTap, enable: true) }
            Log.write("Esc event tap re-enabled after \(type == .tapDisabledByTimeout ? "timeout" : "user input")")
            return Unmanaged.passUnretained(event)
        }
        guard event.getIntegerValueField(.keyboardEventKeycode) == 53 else {
            return Unmanaged.passUnretained(event)
        }
        if type == .keyUp {
            // down 被我们吃掉了，配套的 up 也别单独漏给前台 App
            guard swallowedEscapeDown else { return Unmanaged.passUnretained(event) }
            swallowedEscapeDown = false
            return nil
        }
        guard isListening?() == true else { return Unmanaged.passUnretained(event) }
        swallowedEscapeDown = true
        onEscape?()
        return nil
    }

    private func isPressed(_ e: NSEvent) -> Bool {
        switch choice {
        case .rightOption: return e.modifierFlags.contains(.option)
        case .rightCommand: return e.modifierFlags.contains(.command)
        case .rightControl: return e.modifierFlags.contains(.control)
        case .fn: return e.modifierFlags.contains(.function)
        }
    }

    private func handleFlags(_ e: NSEvent) {
        guard e.keyCode == choice.keyCode else { return }
        let pressed = isPressed(e)
        if pressed {
            guard !down else { return }
            down = true
            confirmed = false
            poisoned = false
            if toggleMode { return }
            onDown?()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.down else { return }
                self.pending = nil
                self.confirmed = true
                self.onConfirm?()
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + holdDelay, execute: work)
        } else {
            guard down else { return }
            down = false
            pending?.cancel()
            pending = nil
            if toggleMode {
                if !poisoned { onToggle?() }
                return
            }
            if confirmed {
                confirmed = false
                onUp?()
            } else {
                onCancel?()
            }
        }
    }

    private func handleKeyDown(_ e: NSEvent) {
        if e.keyCode == 53 { // esc：任何时候都能取消（切换式下录音时手没按着键）
            if !tapOwnsEscape { onEscape?() } // tap 在的时候 esc 归它，这里不重复触发
            return
        }
        guard down else { return }
        if toggleMode {
            poisoned = true   // 说话键 + 别的键 = 快捷键，这一下不算切换
            return
        }
        if !confirmed {
            // 按住说话键期间敲了别的键：这是快捷键，不是说话
            pending?.cancel()
            pending = nil
            down = false
            onCancel?()
        }
    }
}
