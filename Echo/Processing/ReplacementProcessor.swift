import Foundation

struct ReplacementProcessor: TextProcessor, Sendable {
    let rules: [CompiledReplacementRule]
    var literalMode = false

    func process(_ text: String) -> String {
        guard !literalMode, !rules.isEmpty else { return text }
        let source = TextRuleMatcher.normalized(text)
        let protected = TextRuleMatcher.protectedRanges(in: source)
        let strictProtected = TextRuleMatcher.protectedRanges(in: source, includeBareDomains: false)
        var edits: [TextRuleMatcher.Edit] = []
        for (priority, rule) in rules.enumerated() {
            guard !Task<Never, Never>.isCancelled else { return text }
            // Node.js-style case normalization is safe in a bare domain-shaped name;
            // explicit URLs, email and code still remain protected.
            let isCaseOnlyName = TextRuleMatcher.key(rule.misspelling) == TextRuleMatcher.key(rule.word)
                && !rule.misspelling.contains(where: { "/:?#".contains($0) })
            let protectedForRule = isCaseOnlyName ? strictProtected : protected
            rule.regex.enumerateMatches(in: source, range: NSRange(source.startIndex..., in: source)) { match, _, stop in
                guard edits.count < TextRuleMatcher.maximumMatches else { stop.pointee = true; return }
                guard let match, rule.allowProtectedText || !TextRuleMatcher.isProtected(match.range, ranges: protectedForRule),
                      let range = Range(match.range, in: source) else { return }
                edits.append(.init(range: match.range, replacement: replacement(for: rule.word, at: range, in: source), priority: priority))
            }
            if edits.count >= TextRuleMatcher.maximumMatches { break }
        }
        return TextRuleMatcher.apply(edits, to: source)
    }

    private func replacement(for word: String, at range: Range<String.Index>, in text: String) -> String {
        guard word == word.lowercased(), isSentenceStart(range.lowerBound, in: text) else { return word }
        return word.prefix(1).uppercased() + word.dropFirst()
    }

    private func isSentenceStart(_ position: String.Index, in text: String) -> Bool {
        var index = position
        while index > text.startIndex {
            index = text.index(before: index)
            let character = text[index]
            if character.isWhitespace || "\"“‘(".contains(character) { continue }
            return ".!?。！？".contains(character)
        }
        return true
    }
}
