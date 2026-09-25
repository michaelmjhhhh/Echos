import Foundation
import NaturalLanguage

enum TextWordCounter {
    /// Language-aware counts keep unspaced Chinese/Japanese text meaningful in
    /// usage summaries. This measures recognized text separately from snippets.
    static func count(_ text: String, language: String? = nil) -> Int {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        if let language { tokenizer.setLanguage(NLLanguage(rawValue: language)) }
        var count = 0
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { _, _ in
            count += 1
            return true
        }
        return count
    }
}
