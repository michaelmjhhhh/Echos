import Foundation

/// Builds the glossary-style prompt that biases Whisper toward the user's
/// vocabulary. Pure ordering/budgeting logic — token counting is injected so
/// this stays testable without a loaded model.
enum VocabularyPrompt {
    /// Whisper's context window is 448 tokens and the prompt half is 224;
    /// staying under 200 leaves room for the task/language prefill tokens.
    static let defaultTokenBudget = 200

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
