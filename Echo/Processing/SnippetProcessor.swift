import Foundation

/// Expands snippet triggers into their saved text. Two matching modes,
/// mirroring Wispr Flow:
///  - Standalone: the whole utterance is just the trigger (Whisper may append
///    punctuation) — the entire transcript becomes the expansion.
///  - Mid-sentence: triggers match as whole words, case-insensitively.
/// Expansions are always inserted verbatim — they are literal content (emails,
/// links, prompts), so no sentence-capitalization is ever applied.
///
/// Rules arrive longest-trigger-first from `SnippetStore.rules`; like
/// `ReplacementProcessor`, the provider is read per call on the main actor.
struct SnippetProcessor: TextProcessor {
    let rulesProvider: () -> [(trigger: String, expansion: String)]

    func process(_ text: String) -> String {
        standaloneExpansion(of: text) ?? expandMidSentence(text)
    }

    /// The expansion when the entire utterance is a single trigger (Whisper
    /// may append punctuation), or nil. Split out so DictationController can
    /// bypass the polish pass for standalone triggers.
    func standaloneExpansion(of text: String) -> String? {
        let rules = rulesProvider()
        guard !rules.isEmpty else { return nil }
        let standalone = standaloneCandidate(text)
        for rule in rules where standalone.caseInsensitiveCompare(rule.trigger) == .orderedSame {
            return rule.expansion
        }
        return nil
    }

    /// Whole-word, case-insensitive trigger replacement inside a longer
    /// utterance. Runs after the polish pass so expansions are never
    /// rewritten by the model.
    func expandMidSentence(_ text: String) -> String {
        let rules = rulesProvider()
        guard !rules.isEmpty else { return text }
        var result = text
        for rule in rules {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: rule.trigger) + "\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            // Replace back-to-front so earlier ranges stay valid. Manual
            // replacement (not template substitution) keeps "$" and "\" in
            // expansions literal.
            for match in matches.reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                result.replaceSubrange(range, with: rule.expansion)
            }
        }
        return result
    }

    private func standaloneCandidate(_ text: String) -> String {
        var candidate = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        while let last = candidate.last, last.isPunctuation {
            candidate = candidate.dropLast()
        }
        return candidate.trimmingCharacters(in: .whitespaces)
    }
}
