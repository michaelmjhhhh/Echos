import Foundation

/// Expands snippet triggers into their saved text. Two matching modes,
/// mirroring Wispr Flow:
///  - Standalone: the whole utterance is just the trigger (Whisper may append
///    punctuation) — the entire transcript becomes the expansion.
///  - Mid-sentence: triggers match as whole words, case-insensitively.
/// Expansions are always inserted verbatim — they are literal content (emails,
/// links, prompts), so no sentence-capitalization is ever applied.
///
/// Rules arrive longest-trigger-first from `SnippetStore.compiledRules` and
/// are captured as an immutable snapshot for each processing pass.
struct SnippetProcessor: TextProcessor, Sendable {
    let rules: [CompiledSnippetRule]

    func process(_ text: String) -> String {
        guard !rules.isEmpty else { return text }

        // Standalone: strip surrounding whitespace and trailing punctuation,
        // then compare against each trigger whole.
        let standalone = standaloneCandidate(text)
        for rule in rules where standalone.caseInsensitiveCompare(rule.trigger) == .orderedSame {
            return rule.expansion
        }

        var result = text
        for rule in rules {
            let matches = rule.regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
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
