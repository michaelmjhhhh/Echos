import Foundation

/// Whisper was trained on captioned video, so room noise without speech often
/// decodes as a stock caption such as "Thank you." Echo drops these phrases
/// only when the trimmer also found no speech onset; either signal alone is
/// not enough, so a spoken "thank you" is still delivered.
enum SilenceHallucination {
    static let phrases: Set<String> = [
        "you", "thank you", "thank you very much", "thank you so much", "thanks",
        "thanks for watching", "thank you for watching", "bye", "bye bye", "the end",
    ]

    /// Each sentence or comma-separated part must be a caption, so "Thank you,
    /// thank you." is dropped and "Thank you, Priya." is kept.
    /// Text with no letters or digits, such as "*" or "...", is also dropped;
    /// numbers are kept because they may be quiet real speech.
    static func shouldDrop(_ text: String, trimReason: TrimFallbackReason?) -> Bool {
        guard trimReason == .noSpeechOnset, !text.isEmpty else { return false }
        guard text.rangeOfCharacter(from: .alphanumerics) != nil else { return true }
        if text.rangeOfCharacter(from: .decimalDigits) != nil { return false }
        let sentences = text.lowercased()
            .components(separatedBy: CharacterSet(charactersIn: ".,!?\n"))
            .map { $0.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }.joined(separator: " ") }
            .filter { !$0.isEmpty }
        return !sentences.isEmpty && sentences.allSatisfy(phrases.contains)
    }
}
