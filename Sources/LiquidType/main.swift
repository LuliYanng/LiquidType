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
    // Put the HUD up for a few seconds to screenshot its look. --seconds N changes how long (5 s is too short to
    // watch the bars move); --wave draws the bars whatever the setting says; --messages shows every notice and
    // error in turn; --thinking plays what happens after the hotkey is released: talking → thinking → fade out;
    // --learned plays the learned-hotword notice
    if args.contains("--wave") { HUDTuning.shared.previewAsWaveform() }
    let hud = HUD()
    if args.contains("--learned") {
        // Learned-hotword notice: one word, a few, then enough to wrap
        let rounds = [["Pipecat"], ["Pipecat", "Cartesia", "千问"],
                      ["Pipecat", "Cartesia", "千问", "LiquidType", "DashScope", "Samantha", "Claude Code"]]
        for (i, words) in rounds.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.5 * Double(i)) { hud.showLearned(words) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5 * Double(rounds.count)) { exit(0) }
        app.run()
    }
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
