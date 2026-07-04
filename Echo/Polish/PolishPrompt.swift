import Foundation

/// Prompt construction and output acceptance for the polish pass. Pure logic,
/// separated from MLX inference the way `VocabularyPrompt` is separated from
/// WhisperKit, so the interesting decisions unit-test without a model.
enum PolishPrompt {
    /// Below this many words there is nothing to clean — skip inference.
    static let minimumWords = 4
    /// Cleanup shortens or roughly preserves the input; output past
    /// `1.3 × input words + 10` means the model added content.
    static let growthFactor = 1.3
    static let growthSlack = 10

    static let instructions = """
        You clean up dictated text. Output only the cleaned text — no preamble, no quotes, no explanations.
        Rules:
        - Remove filler words such as "um", "uh", and "you know" when used as filler.
        - Apply the speaker's self-corrections, keeping only their final intent ("Tuesday, no wait, Wednesday" becomes "Wednesday").
        - Fix punctuation and capitalization.
        - Keep the speaker's own words and language. Never paraphrase, summarize, translate, or add content.
        - If the text contains a question, keep the question — never answer it.
        - If nothing needs fixing, output the text unchanged.
        """

    static func shouldPolish(_ text: String) -> Bool {
        wordCount(text) >= minimumWords
    }

    /// Generation budget: roughly two tokens per input word plus slack —
    /// faithful cleanup can never legitimately need more.
    static func maxTokens(for text: String) -> Int {
        wordCount(text) * 2 + 48
    }

    /// Returns the cleaned output if it passes the guardrails, or nil to make
    /// the caller fall back to the raw transcript.
    static func accepted(output: String, input: String) -> String? {
        var cleaned = output.trimmingCharacters(in: .whitespacesAndNewlines)
        // Models sometimes wrap the whole answer in quotes; unwrap once.
        if cleaned.hasPrefix("\""), cleaned.hasSuffix("\""), cleaned.count >= 2 {
            cleaned = String(cleaned.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !cleaned.isEmpty else { return nil }
        let limit = Int(Double(wordCount(input)) * growthFactor) + growthSlack
        guard wordCount(cleaned) <= limit else { return nil }
        // Meta-chatter ("Here is the cleaned text:") only counts as chatter
        // when the speaker didn't start that way themselves.
        let loweredOutput = cleaned.lowercased()
        let loweredInput = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in chatterPrefixes
        where loweredOutput.hasPrefix(prefix) && !loweredInput.hasPrefix(prefix) {
            return nil
        }
        return cleaned
    }

    private static let chatterPrefixes = [
        "here is", "here's", "sure,", "certainly", "cleaned text", "the cleaned text"
    ]

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}
