import Foundation

/// Builds the glossary-style prompt that biases Whisper toward the user's
/// vocabulary. Pure ordering/budgeting logic — token counting is injected so
/// this stays testable without a loaded model.
enum VocabularyPrompt {
    /// WhisperKit's decoder context is 224 tokens shared by the prompt, the
    /// prefill tokens and the output. It keeps only the last 111 prompt tokens,
    /// so a longer prompt loses its first (starred) words.
    static let promptTokenLimit = 111
    /// In replay, Distil Large v3 returned empty text for short clips once the
    /// dictionary prompt reached about 100 tokens; 50 tokens was the most
    /// accurate budget for both Tiny and Distil Large v3.
    static let defaultTokenBudget = 50
    static let maximumTokenBudget = 50

    /// Joins `words` (already in priority order — starred first, then newest)
    /// with ", " while the encoded prompt stays within `maxTokens`. Words are
    /// kept whole: one that would overflow is skipped so a shorter, lower
    /// priority word can still use the remaining budget.
    static func text(
        for words: [String],
        maxTokens: Int = defaultTokenBudget,
        budget: (String) -> Int
    ) -> String {
        var included: [String] = []
        for word in words {
            let candidate = (included + [word]).joined(separator: ", ")
            if budget(candidate) <= maxTokens {
                included.append(word)
            }
        }
        return included.joined(separator: ", ")
    }
}
