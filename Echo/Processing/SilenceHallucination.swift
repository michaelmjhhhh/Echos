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

    static func shouldDrop(_ text: String, trimReason: TrimFallbackReason?) -> Bool {
        guard trimReason == .noSpeechOnset else { return false }
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
        return words.isEmpty ? !text.isEmpty : phrases.contains(words.joined(separator: " "))
    }
}
