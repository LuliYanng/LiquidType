import AppKit
import SwiftUI

/// 一把 API key
struct KeySlot: Identifiable {
    let id: Int
    let title: String
    let purpose: String
    let placeholder: String
    let get: () -> String
    let set: (String) -> Void
    /// 按当前选的识别 / LLM，这把是不是非填不可
    let needed: () -> Bool
}

/// 面板和 AppDelegate 之间的那点状态。key 不逐字写 UserDefaults：收起那一行 / 回车 / 关面板时一次存
final class PanelModel: ObservableObject {
    @Published var shownCount = 0            // 每次打开 +1，面板据此回到初始样子
    @Published var drafts: [Int: String] = [:]
    var slots: [KeySlot] = []
    var devMode = false                       // 按住 ⌥ 点图标：多出打开日志

    var onOpenLog: () -> Void = {}
    var onClose: () -> Void = {}

    // Dictionary: learned / added words newest first, the env file's words, and which ones are new
    @Published var words: [String] = []
    @Published var envWords: [String] = []
    @Published var newWords: Set<String> = []
    @Published var learnOn = false

    func reload() {
        drafts = Dictionary(uniqueKeysWithValues: slots.map { ($0.id, $0.get()) })
        reloadWords()
        newWords = Set(Config.shared.newHotwords)
        shownCount += 1
    }

    private func reloadWords() {
        let cfg = Config.shared
        words = cfg.learnedHotwords.reversed()
        envWords = cfg.envHotwords.keys.sorted()
        learnOn = cfg.learnHotwords
    }

    func removeWord(_ word: String) {
        Config.shared.removeLearnedHotword(word)
        Log.write("Dictionary: removed [\(word)]")
        reloadWords()
    }

    func addWord(_ raw: String) {
        let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        let added = Config.shared.addLearnedHotwords([word], byHand: true)
        Log.write("Dictionary: added [\(word)]\(added.isEmpty ? " (already there)" : "")")
        reloadWords()
    }

    func setLearn(_ on: Bool) {
        Config.shared.learnHotwords = on
        Log.write("Dictionary: learn from edits \(on ? "on" : "off")")
        if !on { HotwordLearner.shared.turnedOff() }
        learnOn = on
    }

    func saveKeys() {
        for s in slots {
            let v = (drafts[s.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard v != s.get() else { continue }
            s.set(v)
            Log.write("Set \(s.title) key (\(v.count) chars)")
        }
    }
}

// MARK: - 面板

/// 菜单栏图标底下那块面板，整个 app 唯一的界面：显示方式、识别、LLM、API key、退出。
/// 不用 NSMenu：菜单里放不了能打字的输入框（菜单窗口不会成为 key window，2026-09-08 实测），
/// 也画不了分段开关。设置行原地展开——面板跟内容一样高、不滚动，浮出来的下拉会被窗口边裁掉。
struct MenuPanelView: View {
    static let width: CGFloat = 270
    static let radius: CGFloat = 13
    static let margin: CGFloat = 30          // 面板四周留给阴影的透明边
    static let topGap: CGFloat = 5           // 菜单栏到面板顶边
    static let canvas = NSSize(width: width + margin * 2, height: 640)

    @ObservedObject var model: PanelModel
    @ObservedObject private var tuning = HUDTuning.shared
    @State private var expanded: String?
    @State private var asr = ""
    @State private var llm = ""
    @State private var newWord = ""
    @State private var chipsHeight: CGFloat = 0
    private static let chipsMaxHeight: CGFloat = 132
    @State private var jev = false
    @FocusState private var focusedKey: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !SetupCheck.missing.isEmpty {
                divider
                section {
                    ForEach(SetupCheck.missing, id: \.pane) { item in
                        PanelRow(kind: .action, action: { open(item.pane) }) { _ in
                            Text(item.title).font(.system(size: 12.5)).lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            divider
            section {
                HStack(spacing: 8) {
                    Text("Pill shows").font(.system(size: 13))
                    Spacer()
                    SoftSegments(selection: $tuning.content, options: [
                        (.transcript, "Text"), (.waveform, "Bars"),
                    ])
                }
                .padding(.horizontal, 8).frame(minHeight: 28)

                disclosure("asr", label: "STT", value: ASRModel.find(asr).title) {
                    ForEach(ASRModel.presets, id: \.id) { m in
                        option(m.title, note: m.note, selected: m.id == asr) { pickASR(m) }
                    }
                }
                disclosure("llm", label: "LLM", value: PolishModel.presets.first { $0.id == llm }?.title ?? "—") {
                    ForEach(PolishModel.presets, id: \.id) { m in
                        option(m.title, selected: m.id == llm) { pickLLM(m.id) }
                    }
                }
                // On/off lives here with the other settings; its key sits with the other keys (like LLM → OpenRouter)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Jev fast path").font(.system(size: 13))
                        Text("BETA").font(.system(size: 8.5, weight: .semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 4).padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                        Spacer()
                        Toggle("", isOn: Binding(get: { jev }, set: { setJev($0) }))
                            .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    }
                    .frame(minHeight: 28)
                    // The per-app exceptions (AppStyle.fastPath) shouldn't be a black box
                    Text("Not used in email or Terminal, where cleanup does the formatting")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 8).padding(.bottom, 4)
                disclosure("dict", label: "Dictionary", value: dictionaryValue,
                           valueColor: model.newWords.isEmpty ? .secondary : .accentColor) {
                    dictionary
                }
            }
            divider
            section {
                ForEach(model.slots) { slot in keyRow(slot) }
            }
            divider
            section {
                if model.devMode {
                    PanelRow(kind: .action, action: model.onOpenLog) { _ in
                        Text("Open Log").font(.system(size: 13)); Spacer()
                    }
                }
                PanelRow(kind: .action, action: { NSApp.terminate(nil) }) { _ in
                    Text("Quit LiquidType").font(.system(size: 13)); Spacer()
                }
            }
            .padding(.bottom, -6)
        }
        .padding(.top, 10).padding(.bottom, 4)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        // 圆角、底、描边、阴影全是自己画的：窗口只是一块不动的透明画布（见 MenuPanelController）
        // 光一层 material 压在深色画面上太薄，灰色小字会糊掉：再垫一层半透明窗口底色，跟系统菜单一个浓度
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Self.radius, style: .continuous).strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.16), radius: 9, y: 3)
        .padding(.horizontal, Self.margin).padding(.top, Self.topGap)
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear(perform: reset)
        .onChange(of: model.shownCount) { _, _ in reset() }
    }

    // MARK: 零件

    private var header: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline) {
                Text("LiquidType").font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 6)
                // Which build this is, for the ⌥ panel only
                if model.devMode {
                    Text(AppVersion.summary).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Text(Config.shared.toggleMode
                 ? "Tap fn, speak, tap again"
                 : "Hold fn to talk, release to type")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.top, 2).padding(.bottom, 10)
    }

    private var divider: some View {
        Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1).padding(.horizontal, 12)
    }

    private func section<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .padding(.horizontal, 6).padding(.vertical, 8)
    }

    /// 一行设置，点开后选项原地铺在下面，整块变成一张浅色卡片
    private func disclosure<C: View>(_ id: String, label: String, value: String, valueColor: Color = .secondary,
                                     @ViewBuilder content: () -> C) -> some View {
        let open = expanded == id
        return VStack(spacing: 0) {
            PanelRow(kind: open ? .plain : .select, action: { toggle(id) }) { _ in
                Text(label).font(.system(size: 13))
                Spacer(minLength: 6)
                // 展开后下面的列表已经说明选了哪个，上面再印一遍就是同一句话两种对齐
                if !open { Text(value).font(.system(size: 12)).foregroundStyle(valueColor).lineLimit(1) }
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary).rotationEffect(.degrees(open ? -180 : 0))
            }
            if open { VStack(spacing: 0, content: content).padding(.top, 2).padding(.bottom, 4) }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(open ? 0.08 : 0)))
        .padding(.vertical, open ? 2 : 0)
    }

    private func option(_ title: String, note: String = "", selected: Bool, action: @escaping () -> Void) -> some View {
        PanelRow(kind: .action, minHeight: 26, action: action) { hovered in
            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                .foregroundStyle(hovered ? Color.white : Color.accentColor)
                .opacity(selected ? 1 : 0).frame(width: 15)
            Text(title).font(.system(size: 13, weight: selected ? .medium : .regular)).lineLimit(1)
            Spacer(minLength: 6)
            if !note.isEmpty {
                Text(note).font(.system(size: 11)).foregroundStyle(hovered ? Color.white.opacity(0.8) : Color.secondary).lineLimit(1)
            }
        }
    }

    private func keyRow(_ slot: KeySlot) -> some View {
        let filled = !(model.drafts[slot.id] ?? "").isEmpty
        let id = "key\(slot.id)"
        return disclosure(id, label: slot.title,
                          value: filled ? "Set" : slot.needed() ? "Needed" : "Empty",
                          valueColor: !filled && slot.needed() ? .orange : .secondary) {
            VStack(alignment: .leading, spacing: 5) {
                SecureField(slot.placeholder, text: Binding(get: { model.drafts[slot.id] ?? "" },
                                                            set: { model.drafts[slot.id] = $0 }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 7).frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor).opacity(0.7)))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.12)))
                    .focused($focusedKey, equals: slot.id)
                    .onSubmit { model.saveKeys(); expanded = nil }
                Text(slot.purpose).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.bottom, 3)
        }
    }

    /// Collapsed: how many words, or how many are new since it was last opened
    private var dictionaryValue: String {
        let fresh = model.words.filter(model.newWords.contains).count
        if fresh > 0 { return "\(fresh) new" }
        let n = model.words.count + model.envWords.count
        if n == 0 { return model.learnOn ? "Empty" : "Off" }
        return n == 1 ? "1 word" : "\(n) words"
    }

    /// Words as chips (new ones tinted, the env file's grayed and fixed), a field to add one, and the learning switch
    private var dictionary: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.words.isEmpty && model.envWords.isEmpty {
                Text("Names and terms you add or fix by hand show up here")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                ScrollView(.vertical) {
                    FlowLayout(spacing: 5) {
                        ForEach(model.words.filter(model.newWords.contains) + model.words.filter { !model.newWords.contains($0) },
                                id: \.self) { w in
                            WordChip(word: w, tint: model.newWords.contains(w) ? .fresh : .normal) { model.removeWord(w) }
                        }
                        ForEach(model.envWords, id: \.self) { w in WordChip(word: w, tint: .fixed, onRemove: nil) }
                    }
                    .background(GeometryReader { g in Color.clear.preference(key: HeightKey.self, value: g.size.height) })
                }
                .scrollIndicators(.automatic)
                .frame(height: min(max(chipsHeight, 20), Self.chipsMaxHeight))
                // More below: fade the bottom edge instead of cutting a row in half
                .mask(LinearGradient(stops: [.init(color: .black, location: 0),
                                             .init(color: .black, location: chipsHeight > Self.chipsMaxHeight ? 0.8 : 1),
                                             .init(color: chipsHeight > Self.chipsMaxHeight ? .clear : .black, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .onPreferenceChange(HeightKey.self) { chipsHeight = $0 }
            }
            TextField("Add a word", text: $newWord)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 7).frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor).opacity(0.7)))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.12)))
                .onSubmit { model.addWord(newWord); newWord = "" }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Learn from my edits").font(.system(size: 12.5))
                    Spacer()
                    Toggle("", isOn: Binding(get: { model.learnOn }, set: { model.setLearn($0) }))
                        .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                }
                // Learning runs on the same model as polishing: name it, and say where it's picked
                (Text("Reads back the text you fix after I type. ")
                 + Text(PolishModel.presets.first { $0.id == llm }?.title ?? "The LLM").fontWeight(.medium)
                 + Text(", set under LLM above, picks out the names you corrected"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 8).padding(.top, 2).padding(.bottom, 4)
    }

    // MARK: 动作

    private func reset() {
        asr = ASRModel.find(Config.shared.asrChoice).id
        llm = Config.shared.polishModel
        jev = Config.shared.jevEnabled
        expanded = nil
        // 非填不可的那把还空着：直接把它摊开，光标放进去
        if let s = model.slots.first(where: { $0.needed() && $0.get().isEmpty }) { toggle("key\(s.id)") }
    }

    private func toggle(_ id: String) {
        model.saveKeys()
        expanded = expanded == id ? nil : id
        // Seen now: they stay tinted while the panel is open, not the next time
        if expanded == "dict" { Config.shared.newHotwords = [] }
        let key = expanded.flatMap { $0.hasPrefix("key") ? Int($0.dropFirst(3)) : nil }
        DispatchQueue.main.async { focusedKey = key }
    }

    private func pickASR(_ m: ASRModel) {
        Config.shared.asrChoice = m.id
        asr = m.id
        afterPick()
    }

    private func pickLLM(_ id: String) {
        Config.shared.polishModel = id
        llm = id
        Polisher.startKeepWarm()
        afterPick()
    }

    private func setJev(_ on: Bool) {
        Config.shared.jevEnabled = on
        jev = on
        Log.write("Jev fast path \(on ? "on" : "off")")
        JevGate.startKeepWarm()
        afterPick()
    }

    /// 选完收起；新选的这个缺 key，就顺手把那一行摊开
    private func afterPick() {
        expanded = nil
        if let s = model.slots.first(where: { $0.needed() && (model.drafts[$0.id] ?? "").isEmpty }) { toggle("key\(s.id)") }
    }

    private func open(_ pane: String) {
        if let url = URL(string: pane) { NSWorkspace.shared.open(url) }
        model.onClose()
    }
}

/// 面板里的一行。设置行 hover 是浅灰底（控制中心那种），命令行 hover 是强调色（菜单项那种）——
/// 「识别」和「退出」不是一类东西，眼睛不该读成一类。
private struct PanelRow<Content: View>: View {
    enum Kind { case select, action, plain }
    let kind: Kind
    var minHeight: CGFloat = 28
    let action: () -> Void
    @ViewBuilder let content: (Bool) -> Content
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) { content(hovered && kind == .action) }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
                .foregroundStyle(hovered && kind == .action ? Color.white : Color.primary)
                .background(RoundedRectangle(cornerRadius: 6).fill(fill))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }

    private var fill: Color {
        guard hovered else { return .clear }
        switch kind {
        case .select: return Color.primary.opacity(0.08)
        case .action: return Color.accentColor
        case .plain: return .clear
        }
    }
}

/// One dictionary word. New ones are tinted; the env file's are gray and can't be removed from here
private struct WordChip: View {
    enum Tint { case normal, fresh, fixed }
    let word: String
    let tint: Tint
    let onRemove: (() -> Void)?
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 4) {
            Text(word).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark").font(.system(size: 7.5, weight: .bold))
                        .opacity(hovered ? 0.8 : 0.35)
                        .frame(width: 10, height: 14).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(word)")
            }
        }
        .foregroundStyle(tint == .fixed ? Color.secondary : tint == .fresh ? Color.accentColor : Color.primary)
        .padding(.leading, 7).padding(.trailing, onRemove == nil ? 7 : 4)
        .frame(maxWidth: 220).frame(height: 20)
        .background(RoundedRectangle(cornerRadius: 5).fill(fill))
        .help(tint == .fixed ? "From ~/.liquidtype.env" : "")
        .onHover { hovered = $0 }
    }

    private var fill: Color {
        switch tint {
        case .fresh: return Color.accentColor.opacity(0.16)
        case .fixed: return Color.primary.opacity(0.04)
        case .normal: return Color.primary.opacity(hovered ? 0.11 : 0.07)
        }
    }
}

/// Chips left to right, wrapping onto the next line
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (v, p) in zip(subviews, arrange(subviews, width: bounds.width).origins) {
            v.place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (origins: [CGPoint], width: CGFloat, height: CGFloat) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += s.width + spacing
            rowH = max(rowH, s.height)
            widest = max(widest, x - spacing)
        }
        return (origins, widest, y + rowH)
    }
}

private struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// 二选一的小分段：浅色槽里一颗白色胶囊滑来滑去（控制中心那种），不用系统那个蓝色的 segmented
private struct SoftSegments<T: Hashable>: View {
    @Binding var selection: T
    let options: [(value: T, title: String)]
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { opt in
                let on = opt.value == selection
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { selection = opt.value }
                } label: {
                    Text(opt.title)
                        .font(.system(size: 12, weight: on ? .medium : .regular))
                        .foregroundStyle(on ? Color.primary : Color.secondary)
                        .padding(.horizontal, 11).frame(height: 20)
                        .background {
                            if on {
                                Capsule().fill(Color(nsColor: .controlBackgroundColor))
                                    .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                                    .matchedGeometryEffect(id: "thumb", in: ns)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
    }
}

// MARK: - 窗口宿主

/// 不激活 app 也能当 key window 的无边框面板（Spotlight 那种）：输入框拿得到键盘，前台 app 不丢焦点
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}

final class MenuPanelController: NSObject, NSWindowDelegate {
    let model = PanelModel()
    private var panel: KeyablePanel?
    private var host: NSHostingView<AnyView>?
    private weak var anchor: NSStatusBarButton?
    private var clickMonitor: Any?

    var isVisible: Bool { panel?.isVisible == true }

    func toggle(under button: NSStatusBarButton?) {
        isVisible ? close() : show(under: button)
    }

    func show(under button: NSStatusBarButton?) {
        anchor = button
        let p = panel ?? makePanel()
        model.reload()
        layout()
        p.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { button?.highlight(true) }
        // 点到别的 app / 桌面就收起来
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
    }

    func close() { panel?.orderOut(nil); didHide() }

    func windowDidResignKey(_ notification: Notification) { close() }

    private func didHide() {
        guard clickMonitor != nil else { return }
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        clickMonitor = nil
        model.saveKeys()
        anchor?.highlight(false)
    }

    private func makePanel() -> KeyablePanel {
        let p = KeyablePanel(contentRect: NSRect(origin: .zero, size: MenuPanelView.canvas),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.isReleasedWhenClosed = false
        p.delegate = self

        model.onClose = { [weak self] in self?.close() }
        // 窗口是一块固定大小的透明画布，从不缩放；面板在里面贴着顶边自己长高变矮。
        // 试过让窗口跟着内容缩放：毛玻璃底 + 遮罩 / 阴影在缩回去时会留残影、裁内容（2026-09-21 实测两种写法都翻车）。
        // 透明的地方鼠标直接穿过去，不挡后面的 app。
        let host = NSHostingView(rootView: AnyView(MenuPanelView(model: model)))
        host.sizingOptions = []
        self.host = host
        p.contentView = host
        panel = p
        return p
    }

    /// 画布顶边贴着菜单栏图标底下，左右不出屏幕
    private func layout() {
        guard let p = panel else { return }
        let size = MenuPanelView.canvas
        var origin = p.frame.origin
        if let b = anchor?.window?.frame {
            origin = NSPoint(x: b.midX - size.width / 2, y: b.minY - size.height)
            if let screen = anchor?.window?.screen?.visibleFrame {
                let m = MenuPanelView.margin - 8
                origin.x = min(max(origin.x, screen.minX - m), screen.maxX - size.width + m)
            }
        }
        p.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}
