import Foundation

/// A stage in the post-transcription pipeline. Raw Whisper output flows through
/// each processor in order before insertion — this is the hook where a local
/// LLM cleanup stage can be added later.
protocol TextProcessor {
    func process(_ text: String) -> String
}

/// Trims surrounding whitespace and collapses internal runs of whitespace,
/// which Whisper occasionally emits around segment boundaries.
struct WhitespaceCleanupProcessor: TextProcessor {
    func process(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
