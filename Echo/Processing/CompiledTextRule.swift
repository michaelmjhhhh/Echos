import Foundation

/// Immutable, precompiled dictionary replacement rule.
/// `NSRegularExpression` is safe for concurrent matching after construction;
/// Echo never mutates a published rule snapshot.
struct CompiledReplacementRule: @unchecked Sendable {
    let misspelling: String
    let word: String
    let regex: NSRegularExpression

    init?(misspelling: String, word: String) {
        guard !misspelling.isEmpty else { return nil }
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: misspelling) + "\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        self.misspelling = misspelling
        self.word = word
        self.regex = regex
    }
}

/// Immutable, precompiled snippet expansion rule.
struct CompiledSnippetRule: @unchecked Sendable {
    let trigger: String
    let expansion: String
    let regex: NSRegularExpression

    init?(trigger: String, expansion: String) {
        guard !trigger.isEmpty else { return nil }
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: trigger) + "\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        self.trigger = trigger
        self.expansion = expansion
        self.regex = regex
    }
}
