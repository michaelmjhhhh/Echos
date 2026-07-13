import Foundation

/// Applies the dictionary's misspelling → word rules to a transcript.
/// Matches whole words case-insensitively; rules arrive longest-first from
/// `DictionaryStore.replacementRules` so overlaps resolve predictably.
///
/// Rules are compiled when the dictionary changes and captured as an
/// immutable snapshot for each processing pass.
struct ReplacementProcessor: TextProcessor, Sendable {
    let rules: [CompiledReplacementRule]

    func process(_ text: String) -> String {
        var result = text
        for rule in rules {
            let matches = rule.regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            // Replace back-to-front so earlier ranges stay valid.
            for match in matches.reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                result.replaceSubrange(range, with: replacement(for: rule.word, at: range, in: result))
            }
        }
        return result
    }

    /// The stored spelling, except sentence starts re-capitalize all-lowercase
    /// words ("recieve → receive" must not decapitalize "Receive my thanks.").
    /// Mixed-case words ("iPhone") are always inserted verbatim.
    private func replacement(for word: String, at range: Range<String.Index>, in text: String) -> String {
        guard word == word.lowercased(), isSentenceStart(range.lowerBound, in: text) else { return word }
        return word.prefix(1).uppercased() + word.dropFirst()
    }

    private func isSentenceStart(_ position: String.Index, in text: String) -> Bool {
        var index = position
        while index > text.startIndex {
            index = text.index(before: index)
            let character = text[index]
            if character.isWhitespace || character == "\"" || character == "“" { continue }
            return ".!?".contains(character)
        }
        return true // start of the transcript
    }
}
