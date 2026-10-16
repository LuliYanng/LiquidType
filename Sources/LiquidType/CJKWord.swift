import Foundation
import NaturalLanguage

/// Grows a Chinese fix to the whole word it sits in. When the user changes one character of a name
/// (陈晨 → 陈辰), what comes back is just the changed part ("辰"), and a one-character hotword is useless.
/// Names come from NLTagger (it finds 张伟, 王晓明); other words the system doesn't know, CFStringTokenizer
/// splits into single characters, so the run of single-character tokens around the fix is the unknown
/// word. NLTagger joins greedily ("陈晨发" for 给陈晨发消息), so particles and common verbs at the edges
/// (给, 发, 的, 了…) are trimmed off. Anything longer than four characters is left as it was.
enum CJKWord {
    private static let edgeChars = Set("给发叫找跟和与同对向把被让请问说是在的了吧呢啊嘛用到去来从")

    /// `word` as found in `text`, grown to its whole word when it's Chinese; otherwise `word` itself
    static func whole(_ word: String, in text: String) -> String {
        guard word.allSatisfy(isCJK), word.count < 4 else { return word }
        let chars = Array(text), w = Array(word)
        guard w.count <= chars.count,
              let start = (0...(chars.count - w.count)).first(where: { Array(chars[$0..<$0 + w.count]) == w }) else { return word }
        return String(chars[expand(chars, start: start, length: w.count)])
    }

    /// The character range of the word around `start..<start + length` in `chars`
    static func expand(_ chars: [Character], start: Int, length: Int) -> Range<Int> {
        let text = String(chars)
        let target = start..<(start + length)
        func offset(_ i: String.Index) -> Int { text.distance(from: text.startIndex, to: i) }
        var span = target
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        tagger.setLanguage(.simplifiedChinese, range: text.startIndex..<text.endIndex)
        var found = false
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: [.joinNames, .omitPunctuation, .omitWhitespace]) { tag, r in
            let range = offset(r.lowerBound)..<offset(r.upperBound)
            if tag == .personalName, range.lowerBound <= target.lowerBound, range.upperBound >= target.upperBound {
                span = range; found = true; return false
            }
            return true
        }
        if !found {
            // The run of single-character tokens the fix sits in
            let cf = text as CFString
            let tokenizer = CFStringTokenizerCreate(nil, cf, CFRange(location: 0, length: CFStringGetLength(cf)), kCFStringTokenizerUnitWordBoundary, Locale(identifier: "zh_CN") as CFLocale)
            var singles: [Range<Int>] = []
            let ns = text as NSString
            while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
                let r = CFStringTokenizerGetCurrentTokenRange(tokenizer)
                // UTF-16 to character offsets; only single Han characters matter here
                let lo = (ns.substring(to: r.location) as String).count
                let piece = ns.substring(with: NSRange(location: r.location, length: r.length))
                if piece.count == 1, piece.first.map(isCJK) == true { singles.append(lo..<(lo + 1)) }
            }
            var lo = target.lowerBound, hi = target.upperBound
            while singles.contains(where: { $0.upperBound == lo }) { lo -= 1 }
            while singles.contains(where: { $0.lowerBound == hi }) { hi += 1 }
            span = min(lo, target.lowerBound)..<max(hi, target.upperBound)
        }
        var lo = span.lowerBound, hi = span.upperBound
        while lo < target.lowerBound, edgeChars.contains(chars[lo]) { lo += 1 }
        while hi > target.upperBound, edgeChars.contains(chars[hi - 1]) { hi -= 1 }
        guard hi - lo <= 4, (lo..<hi).allSatisfy({ isCJK(chars[$0]) }) else { return target }
        return lo..<hi
    }

    static func isCJK(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) || (0x20000...0x2A6DF).contains($0.value) }
    }
}
