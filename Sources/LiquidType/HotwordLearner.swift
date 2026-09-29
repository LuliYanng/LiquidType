import AppKit

/// Learns hotwords from the user's own corrections. After a dictation is typed in, it keeps reading the
/// text field back through Accessibility and finds the typed passage again by the text right around it.
/// When the user is done with the passage, the last version seen is compared with what was typed, and
/// the LLM picks out the proper nouns and terms the user fixed by hand: one request per passage.
///
/// "Done" is the same rule in every app: the user has moved on from the passage and the text has stopped
/// changing. Moved on = the caret left the passage (the part that came from the dictation, not what the
/// user wrote after it), or another app came to the front, or another field took focus in this one (the
/// caret stays put when the user just switches away). Moving between words
/// inside it, or composing with an input method, isn't done however long it takes. The passage being gone
/// from the field (a chat box sent) or the next dictation end it at once. Time only backs this up: where
/// the caret can't be read, `settleAfter` seconds without an edit; where it can but never leaves,
/// `idleFallback`; and `window` at most.
///
/// Every step logs a "Learn:" line: which apps expose their text fields is something to find out
/// app by app, and a field that can't be read just means nothing is learned this time.
final class HotwordLearner {
    static let shared = HotwordLearner()
    var onLearned: (([String]) -> Void)?

    private struct Watch {
        let app: String
        let pid: pid_t
        let element: AXUIElement
        let inserted: String
        let before: String         // text just before the typed passage when it went in; "" at the field's start
        let after: String          // text just after it; "" at the field's end
        var start: Int             // where the passage started last time (UTF-16), to find `before` near it
        var latest: String         // the passage as last seen
        var changes = 0            // snapshots that differed from the one before
        let began = Date()
        var lastEdit = Date()      // last snapshot that differed; the settle clock runs from here
        var longestPause: TimeInterval = 0   // longest gap between two edits, to see how people actually edit
        var core: String           // the part of `latest` that came from the dictation (see dictatedSpan)
        var caretSeen = false      // the field reported a caret at least once
        var caretWasInside = false // ...and it sat in the dictated span at some point: only then is "left" believable
        var caretNote = "no caret" // last caret vs dictated span, for the stop log line
        var lastSelection: NSRange? // caret as of the previous look, to tell a moved caret from one left by typing
    }

    private var watch: Watch?
    private var timer: Timer?
    private var pending: DispatchWorkItem?

    private static let contextLength = 24
    private static let maxFieldLength = 20_000
    private static let window: TimeInterval = 45
    private static let settleAfter: TimeInterval = 6   // no caret to go by; longest pause between edits in early use: 5 s
    private static let idleFallback: TimeInterval = 15 // caret readable but it never left the passage
    private static let pollInterval: TimeInterval = 0.5   // edit-then-Enter in a chat box can be quick

    /// Right after `inserted` was typed into `app`. Starts a new watch (ending any previous one)
    func track(inserted: String, in app: NSRunningApplication?) {
        stop(reason: "new text")
        guard Config.shared.learnHotwords else { return }
        guard let app, !inserted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        schedule(after: 0.35) { [weak self] in self?.begin(inserted: inserted, app: app, attempt: 1) }
    }

    /// Ends the current watch now and evaluates what it has
    func stop(reason: String) {
        pending?.cancel()
        pending = nil
        timer?.invalidate()
        timer = nil
        guard let w = watch else { return }
        watch = nil
        let secs = Int(Date().timeIntervalSince(w.began))
        let edits = w.changes == 0 ? "no edits"
            : "\(w.changes) change(s), last at \(Int(w.lastEdit.timeIntervalSince(w.began)))s, longest pause \(Int(w.longestPause))s"
        Log.write("Learn: stop (\(reason)) after \(secs)s, \(edits), \(w.caretNote) [\(w.core)]")
        evaluate(inserted: w.inserted, final: w.core)
    }

    /// Learning was switched off: drop the current watch without sending anything. Assistive mode stays:
    /// typing reads the focus with it too (see AssistiveMode)
    func turnedOff() {
        pending?.cancel()
        pending = nil
        timer?.invalidate()
        timer = nil
        if watch != nil { Log.write("Learn: switched off, dropped the current watch") }
        watch = nil
    }

    // MARK: - Watching

    private func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) {
        let item = DispatchWorkItem(block: work)
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Keystrokes land asynchronously and a Chromium app builds its accessibility tree lazily once asked,
    /// so a miss is retried a couple of times before giving up
    private func begin(inserted: String, app: NSRunningApplication, attempt: Int) {
        pending = nil
        let name = "\(app.localizedName ?? "?") [\(app.bundleIdentifier ?? "")]"
        let retry = { [weak self] (why: String) in
            guard let self else { return }
            if attempt < 5 {
                self.schedule(after: 0.5) { [weak self] in self?.begin(inserted: inserted, app: app, attempt: attempt + 1) }
            } else {
                Log.write("Learn: can't watch \(name): \(why)")
            }
        }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appEl, 0.3)
        AssistiveMode.shared.enable(for: app)

        guard let el: AXUIElement = Self.attribute(appEl, kAXFocusedUIElementAttribute) else {
            retry("no focused element"); return
        }
        AXUIElementSetMessagingTimeout(el, 0.3)
        let role: String = Self.attribute(el, kAXRoleAttribute) ?? "?"
        let subrole: String = Self.attribute(el, kAXSubroleAttribute) ?? ""
        if subrole == (kAXSecureTextFieldSubrole as String) {
            Log.write("Learn: skip \(name): secure text field"); return
        }
        guard let value = Self.value(of: el) else {
            retry("no text value (role=\(role) \(subrole))"); return
        }
        // A whole document read back every half second would stall the main thread; a big field isn't a chat box
        guard (value as NSString).length <= Self.maxFieldLength else {
            Log.write("Learn: skip \(name): field too large (\((value as NSString).length) chars)"); return
        }
        let ns = value as NSString
        let len = (inserted as NSString).length
        // The passage normally ends right at the caret; otherwise take the occurrence closest before it
        let caret = Self.caret(of: el) ?? ns.length
        var loc = NSNotFound
        if caret >= len, caret <= ns.length, ns.substring(with: NSRange(location: caret - len, length: len)) == inserted {
            loc = caret - len
        } else {
            let upTo = max(0, min(ns.length, caret + len))
            loc = ns.range(of: inserted, options: [.backwards, .literal], range: NSRange(location: 0, length: upTo)).location
            if loc == NSNotFound { loc = ns.range(of: inserted, options: [.backwards, .literal]).location }
        }
        guard loc != NSNotFound else {
            // Lengths only: the rest of the field is the user's own text, not something they dictated. A field
            // shorter than the text is what's left of the typing itself (keystrokes lost on the way), shown in full
            let debris = ns.length < len ? " [\(value)]" : ""
            let since = AssistiveMode.shared.since(app.processIdentifier).map { ", assistive mode on for \(Int(Date().timeIntervalSince($0)))s" } ?? ""
            retry("typed text not in field (role=\(role), \(ns.length) chars\(debris), caret \(caret)\(since))"); return
        }
        let c = Self.contextLength
        // Anchors snap to whole characters, so an emoji at the cut doesn't break them
        let beforeRange = ns.rangeOfComposedCharacterSequences(for: NSRange(location: max(0, loc - c), length: min(c, loc)))
        let before = ns.substring(with: NSRange(location: beforeRange.location, length: loc - beforeRange.location))
        let afterStart = loc + len
        let afterRange = ns.rangeOfComposedCharacterSequences(for: NSRange(location: afterStart, length: min(c, ns.length - afterStart)))
        let after = ns.substring(with: afterRange)
        let caretSeen = Self.selection(of: el) != nil
        watch = Watch(app: name, pid: app.processIdentifier, element: el, inserted: inserted, before: before, after: after,
                      start: loc, latest: inserted,
                      core: inserted, caretSeen: caretSeen)
        Log.write("Learn: watching \(name) role=\(role) \(subrole) field=\(ns.length) chars at \(loc), attempt \(attempt), caret \(caretSeen ? "yes" : "no")")
        let t = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func poll() {
        guard Config.shared.learnHotwords else { turnedOff(); return }
        guard var w = watch else { return }
        if Date().timeIntervalSince(w.began) > Self.window { stop(reason: "time's up"); return }
        guard let value = Self.value(of: w.element) else { stop(reason: "field gone"); return }
        guard (value as NSString).length <= Self.maxFieldLength else { stop(reason: "field grew too large"); return }
        guard let (start, passage) = Self.locate(in: value as NSString, before: w.before, after: w.after, near: w.start,
                                                 nearEnd: w.start + (w.latest as NSString).length) else {
            stop(reason: value.isEmpty ? "field cleared" : "surrounding text changed"); return
        }
        // Nothing left where the passage was: it was sent or deleted, and the last version seen is the one to learn from
        if passage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { stop(reason: "passage cleared"); return }
        // With no text around it to anchor on (the passage was the whole field), anything the field turns into
        // looks like an edit: the address bar showing the page it went to, say. Little of the typed text left = gone.
        // Not for a short passage, where retyping the one misheard word is exactly the edit to learn from
        if passage != w.latest, w.before.isEmpty, w.after.isEmpty, w.inserted.count >= 12,
           Self.kept(of: w.inserted, in: passage) < 0.3 {
            stop(reason: "field holds other text now (\(passage.count) chars)"); return
        }
        // Something big pasted in next to it: aligning it every half second would stall the app, and the passage
        // is no longer a dictation with a few fixes (evaluate would skip it anyway)
        if passage.count > w.inserted.count * 3 + 200 { stop(reason: "passage grew too large"); return }
        let now = Date()
        let stable = passage == w.latest
        if !stable {
            if w.changes > 0 { w.longestPause = max(w.longestPause, now.timeIntervalSince(w.lastEdit)) }
            w.changes += 1
            w.lastEdit = now
        }
        let pns = passage as NSString
        let span = Self.dictatedSpan(of: w.inserted, in: passage)
        w.start = start
        w.latest = passage
        w.core = pns.substring(with: span)
        let selection = Self.selection(of: w.element)
        let caretMoved = stable && selection != nil && w.lastSelection != nil && selection != w.lastSelection
        let away = selection.map { sel -> Bool in
            let rel = NSRange(location: sel.location - start, length: sel.length)
            if Self.caretIsAway(rel, from: span, passageLength: pns.length) { return true }
            // Moved (not typed) to right after the passage's closing punctuation once edits were made: finished,
            // not still working on its last word. Typing leaves the caret there too, and so does the insert,
            // hence "moved" and the edits; a trailing space doesn't count, it's mid-edit as often as not
            return w.changes > 0 && caretMoved && rel.length == 0 && rel.location == span.location + span.length
                && Self.endsWithPunctuation(pns.substring(with: span))
        }
        w.lastSelection = selection
        if selection != nil { w.caretSeen = true }
        if let sel = selection {
            w.caretNote = "caret \(sel.location - start)+\(sel.length) vs span \(span.location)-\(span.location + span.length) of \(pns.length)"
        }
        if away == false { w.caretWasInside = true }
        watch = w
        // Done: the user moved on and the text held still since the last look. A field whose caret never showed
        // up inside the passage (stuck at 0, say) isn't trusted on the caret; the other two still count
        if stable {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != w.pid { stop(reason: "switched to another app"); return }
            if !Self.stillFocused(w.element, pid: w.pid, holding: passage) { stop(reason: "moved to another field"); return }
            if away == true, w.caretWasInside { stop(reason: "cursor left the passage"); return }
        }
        let idle = now.timeIntervalSince(w.lastEdit)
        let limit = w.caretWasInside ? Self.idleFallback : Self.settleAfter
        if idle >= limit {
            stop(reason: w.changes == 0 ? "no edits in \(Int(limit))s" : "settled \(Int(limit))s after the last edit")
        }
    }

    /// Where, in `passage` (UTF-16), the dictated text sits now: from the first to the last character still
    /// lined up with it, plus what replaced dictated text at either end (text deleted there and typed in its
    /// place: 派普凯特 → Pipecat as the last word), plus Latin letters and digits running on from a word at
    /// either end ("Com" → "ComfyUI"). Anything else the user wrote before or after it is left out, CJK text
    /// included: it has no spaces to tell a word apart from the user's next sentence
    static func dictatedSpan(of inserted: String, in passage: String) -> NSRange {
        let old = Array(inserted.utf16), p = Array(passage.utf16)
        var removed = Set<Int>(), added = Set<Int>()
        for change in p.difference(from: old) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): added.insert(offset)
            }
        }
        // Where in `passage` each deletion happened
        var deletedAt = Set<Int>()
        var i = 0, j = 0
        while i < old.count || j < p.count {
            if removed.contains(i) { deletedAt.insert(j); i += 1 }
            else if added.contains(j) { j += 1 }
            else { i += 1; j += 1 }
        }
        guard let first = p.indices.first(where: { !added.contains($0) }),
              let last = p.indices.last(where: { !added.contains($0) }) else { return NSRange(location: 0, length: p.count) }
        var lo = first, hi = last + 1
        // A run of new text at either end joins the span if dictated text was deleted within it (a replacement)
        var runEnd = hi
        while runEnd < p.count, added.contains(runEnd) { runEnd += 1 }
        if (hi...runEnd).contains(where: deletedAt.contains) { hi = runEnd }
        var runStart = lo
        while runStart > 0, added.contains(runStart - 1) { runStart -= 1 }
        if (runStart...lo).contains(where: deletedAt.contains) { lo = runStart }
        func latin(_ u: UInt16) -> Bool { u < 0x80 ? (u >= 0x30 && u <= 0x39) || ((u | 0x20) >= 0x61 && (u | 0x20) <= 0x7A) : (u >= 0xC0 && u <= 0x24F) }
        if latin(p[hi - 1]) { while hi < p.count, latin(p[hi]) { hi += 1 } }
        if latin(p[lo]) { while lo > 0, latin(p[lo - 1]) { lo -= 1 } }
        return NSRange(location: lo, length: hi - lo)
    }

    /// Ends in punctuation ("…了呀。", "…ComfyUI?"), not mid-word or on a space
    static func endsWithPunctuation(_ s: String) -> Bool {
        guard let last = s.unicodeScalars.last else { return false }
        return CharacterSet.punctuationCharacters.contains(last)
    }

    /// The caret or selection (relative to the passage) is clear of the dictated span, not touching it
    static func caretIsAway(_ sel: NSRange, from span: NSRange, passageLength: Int) -> Bool {
        let lo = sel.location, hi = sel.location + sel.length
        return hi < span.location || lo > span.location + span.length
    }

    /// The passage is whatever now sits between the text that was right before it and right after it
    private static func locate(in ns: NSString, before: String, after: String, near: Int, nearEnd: Int) -> (Int, String)? {
        var start = 0
        if !before.isEmpty {
            // The same words can come right before other passages too (say the same sentence twice and both end
            // alike): of every match within reach, take the one ending closest to where the passage started last time
            let from = min(ns.length, max(0, near - (before as NSString).length - 2000))
            let to = min(ns.length, near + 2000)
            var best: Int?
            var cursor = from
            while cursor < to {
                let r = ns.range(of: before, options: [], range: NSRange(location: cursor, length: to - cursor))
                guard r.location != NSNotFound else { break }
                let end = r.location + r.length
                if best == nil || abs(end - near) < abs(best! - near) { best = end }
                cursor = r.location + 1
            }
            guard let best else { return nil }
            start = best
        }
        var end = ns.length
        if !after.isEmpty {
            // Likewise the nearest match to where the passage ended: a short anchor like "\n" also turns up
            // inside a multi-line passage, and the first one would cut it short
            var best: Int?
            var cursor = start
            while cursor < ns.length {
                let r = ns.range(of: after, options: [], range: NSRange(location: cursor, length: ns.length - cursor))
                guard r.location != NSNotFound else { break }
                if best == nil || abs(r.location - nearEnd) < abs(best! - nearEnd) { best = r.location }
                if r.location > nearEnd + 2000 { break }
                cursor = r.location + 1
            }
            guard let best else { return nil }
            end = best
        }
        return (start, ns.substring(with: NSRange(location: start, length: end - start)))
    }

    /// Share of `typed` still there, in order, in `now` (ignoring case: fixing it is an edit, not new text)
    static func kept(of typed: String, in now: String) -> Double {
        let a = Array(typed.lowercased())
        guard !a.isEmpty else { return 1 }
        let removed = Array(now.lowercased()).difference(from: a).removals.count
        return Double(a.count - removed) / Double(a.count)
    }

    // MARK: - Learning

    private func evaluate(inserted: String, final: String) {
        guard Config.shared.learnHotwords else { return }
        let a = inserted.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = final.trimmingCharacters(in: .whitespacesAndNewlines)
        guard a != b else { Log.write("Learn: unchanged"); return }
        guard b.count <= a.count * 3 + 200 else { Log.write("Learn: skip, passage grew from \(a.count) to \(b.count) chars"); return }
        let user = "<before>\n\(a)\n</before>\n<after>\n\(b)\n</after>"
        Polisher.request(system: Self.prompt, user: user, fallback: "", timeout: 15, label: "Learn") { [weak self] text, ok in
            guard ok else { return }
            let found = Self.parse(text)
            // Only a spelling the user typed over something else (not text they merely added), and one that wasn't there already
            let words = found.filter { $0.count <= 40 && !a.contains($0) && Self.typedOver($0, from: a, to: b) }
            if words.count < found.count { Log.write("Learn: dropped \(found.filter { !words.contains($0) }) (added, not corrected)") }
            let rejected = Set(Config.shared.rejectedHotwords.map { $0.lowercased() })
            let undone = words.filter { rejected.contains($0.lowercased()) }
            if !undone.isEmpty { Log.write("Learn: skipped \(undone) (undone before)") }
            let added = Config.shared.addLearnedHotwords(words)
            Config.shared.newHotwords += added
            Log.write("Learn: LLM \(text.replacingOccurrences(of: "\n", with: " ")) → added \(added)")
            if !added.isEmpty { self?.onLearned?(added) }
        }
    }

    /// Whether the user typed `word` over something in `old`, rather than merely adding it: somewhere it
    /// appears in `new`, part of it was already there (Jason → Jayson), text was deleted right where it
    /// was typed in (cloud code → Claude Code), or text was only deleted inside it (Hugging Face →
    /// HuggingFace). A word that is entirely new text with no deletion next to it was added, not corrected.
    static func typedOver(_ word: String, from old: String, to new: String) -> Bool {
        let a = Array(old), b = Array(new), w = Array(word)
        guard !w.isEmpty, w.count <= b.count else { return false }
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in b.difference(from: a) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        // Walk both sides in step to see where in `new` each deletion happened
        var deletedAt = Set<Int>()
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if removed.contains(i) { deletedAt.insert(j); i += 1 }
            else if inserted.contains(j) { j += 1 }
            else { i += 1; j += 1 }
        }
        for start in 0...(b.count - w.count) where Array(b[start..<start + w.count]) == w {
            let r = start..<start + w.count
            // Nothing typed in it, but something deleted between its letters: a pure-deletion fix
            if !r.contains(where: inserted.contains) {
                if (r.lowerBound + 1..<r.upperBound).contains(where: deletedAt.contains) { return true }
                continue
            }
            if !r.allSatisfy(inserted.contains) { return true }
            // Entirely new: stretch to the whole inserted run and look for a deletion inside or at its edges
            var lo = r.lowerBound, hi = r.upperBound
            while lo > 0, inserted.contains(lo - 1) { lo -= 1 }
            while hi < b.count, inserted.contains(hi) { hi += 1 }
            if (lo...hi).contains(where: deletedAt.contains) { return true }
        }
        return false
    }

    private static func parse(_ text: String) -> [String] {
        guard let open = text.firstIndex(of: "["), let close = text.lastIndex(of: "]"), open < close,
              let data = String(text[open...close]).data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        return arr.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    static let prompt = """
    You compare two versions of the same passage. <before> is what a speech-to-text app typed into a text field. \
    <after> is that passage after the user edited it by hand; it may also include text the user added around it.

    Find where the user replaced a word or phrase with a proper noun, name, brand, product, or technical term that \
    sounds the same or similar when spoken. That means speech recognition misheard it and the user fixed the spelling.

    Each term must replace something that is in <before>. Never include a term that only appears in text the user \
    added. Ignore everything else: rewording, added or deleted content, punctuation, grammar, and fixes to ordinary words.

    Reply with only a JSON array of the corrected terms, written exactly as in <after>. Reply [] if there are none.

    Examples
    <before>我们用派普凯特搭一个语音 agent 吧。</before> <after>我们用 Pipecat 搭一个语音 agent 吧。</after> → ["Pipecat"]
    <before>Let's ask Jason about the cloud code setup.</before> <after>Let's ask Jayson about the Claude Code setup, and the MCP server too.</after> → ["Jayson", "Claude Code"]
    <before>明天下午三点开会。</before> <after>明天下午四点开会，记得带电脑。</after> → []
    <before>这个做的不错</before> <after>这个做得不错！</after> → []
    """

    // MARK: - AX helpers

    private static func attribute<T>(_ el: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v as? T
    }

    private static func value(of el: AXUIElement) -> String? {
        attribute(el, kAXValueAttribute)
    }

    /// Whether `el` is still the focused element of its app (another field clicked in the same app = moved on).
    /// Chromium can hand out a fresh object for the same field, so one still holding the passage counts as it.
    /// If the app won't say, assume it is: that's the caret's and time's call then
    private static func stillFocused(_ el: AXUIElement, pid: pid_t, holding passage: String) -> Bool {
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.3)
        guard let focused: AXUIElement = attribute(appEl, kAXFocusedUIElementAttribute) else { return true }
        if CFEqual(focused, el) { return true }
        return value(of: focused)?.contains(passage) ?? false
    }

    /// The selection, or the caret as an empty one, in the field's UTF-16 units
    private static func selection(of el: AXUIElement) -> NSRange? {
        guard let v: AXValue = attribute(el, kAXSelectedTextRangeAttribute) else { return nil }
        var r = CFRange()
        guard AXValueGetValue(v, .cfRange, &r), r.location >= 0 else { return nil }
        return NSRange(location: r.location, length: r.length)
    }

    private static func caret(of el: AXUIElement) -> Int? {
        guard let v: AXValue = attribute(el, kAXSelectedTextRangeAttribute) else { return nil }
        var r = CFRange()
        guard AXValueGetValue(v, .cfRange, &r) else { return nil }
        return r.location + r.length
    }
}
