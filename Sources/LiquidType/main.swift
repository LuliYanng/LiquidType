import AppKit

let args = CommandLine.arguments
if args.count >= 3, args[1] == "--test-asr" {
    SelfTest.run(wavPath: args[2])
}
if args.count >= 3, args[1] == "--test-polish" {
    // `LiquidType --test-polish "原文" [样式标签]`：只跑润色，打印结果（ok=false 表示回退了原文）
    let style = args.count >= 4 ? (AppStyle.named(args[3]) ?? .generic) : .generic
    Polisher.polish(args[2], style: style, appName: nil) { text, ok in
        print("[\(style.label) ok=\(ok)] \(text)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exit(0) }  // 等异步日志落盘
    }
    RunLoop.main.run()
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

if args.count >= 2, args[1] == "--probe-url" {
    // 对每个正在运行的浏览器试一次 URL 探测（AX 优先，AppleScript 兜底），验证站点识别
    for a in NSWorkspace.shared.runningApplications where WebContext.isBrowser(a) {
        let m = WebContext.detect(a)
        print("\(a.localizedName ?? "?") [\(a.bundleIdentifier ?? "")]: \(m.map { "\($0.site.label) ← \($0.url)" } ?? "未匹配/拿不到")")
    }
    exit(0)
}

if args.count >= 2, args[1] == "--preview-hud" {
    // 只把 HUD 摆出来几秒，用来截图看样式；--seconds N 改停留时长（看波形动起来 5 秒不够），
    // --wave 不管设置里选的是什么，这次都按波形画；--messages 把所有提示 / 报错挨个摆一遍；--thinking 走一遍松开热键之后的样子：说话 → 思考中 → 淡出
    if args.contains("--wave") { HUDTuning.shared.previewAsWaveform() }
    let hud = HUD()
    hud.showPreview()
    Log.write("HUD preview: glass=\(hud.usesGlass) variant=\(String(describing: hud.glassVariant)) frame=\(hud.debugFrame) mouse=\(NSEvent.mouseLocation)")
    if args.contains("--messages") {
        // 把所有提示 / 报错挨个摆一遍（每条 2 秒），看放不放得下、撑宽顺不顺
        for (i, msg) in HUDCopy.all.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1 + 2 * Double(i)) { hud.show(.error, message: msg) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1 + 2 * Double(HUDCopy.all.count)) { exit(0) }
        app.run()
    }
    if args.contains("--thinking") {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { hud.show(.thinking) }
        // --nothing：思考中之后接「没听到内容」（看胶囊撑宽），否则直接淡出
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
            if args.contains("--nothing") {
                hud.show(.info, message: HUDCopy.noSpeech)
                hud.hide(after: 1.2)
            } else {
                hud.hide()
            }
        }
    }
    let seconds = args.firstIndex(of: "--seconds").flatMap { args.indices.contains($0 + 1) ? Double(args[$0 + 1]) : nil } ?? 5
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
    app.run()
}

let delegate = AppDelegate()
app.delegate = delegate
app.run()
