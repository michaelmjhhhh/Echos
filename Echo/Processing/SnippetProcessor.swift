import Foundation

/// Dictionary processing may intentionally produce a snippet trigger. Expansions are
/// opaque within this final stage, including literal whitespace, dollars and backslashes.
struct SnippetProcessor: TextProcessor, Sendable {
    let rules: [CompiledSnippetRule]
    var literalMode = false

    func process(_ text: String) -> String {
        guard !literalMode, !rules.isEmpty else { return text }
        let source = TextRuleMatcher.normalized(text)
        let protected = TextRuleMatcher.protectedRanges(in: source)
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        // Check the complete trigger first, so punctuation in C++, .NET, etc. is literal.
        var candidate = trimmed
        while !candidate.isEmpty {
            for rule in rules {
                if TextRuleMatcher.key(candidate) == TextRuleMatcher.key(rule.trigger),
                   rule.allowProtectedText || protected.isEmpty,
                   rule.expansion.utf16.count <= TextRuleMatcher.maximumOutputUTF16Count {
                    return rule.expansion
                }
            }
            guard let last = candidate.last, ".!?。！？,，;；:：".contains(last) else { break }
            candidate.removeLast()
            candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var edits: [TextRuleMatcher.Edit] = []
        for (priority, rule) in rules.enumerated() where !rule.standaloneOnly {
            guard !Task<Never, Never>.isCancelled else { return text }
            rule.regex.enumerateMatches(in: source, range: NSRange(source.startIndex..., in: source)) { match, _, stop in
                guard edits.count < TextRuleMatcher.maximumMatches else { stop.pointee = true; return }
                guard let match, rule.allowProtectedText || !TextRuleMatcher.isProtected(match.range, ranges: protected) else { return }
                edits.append(.init(range: match.range, replacement: rule.expansion, priority: priority))
            }
            if edits.count >= TextRuleMatcher.maximumMatches { break }
        }
        return TextRuleMatcher.apply(edits, to: source)
    }
}
