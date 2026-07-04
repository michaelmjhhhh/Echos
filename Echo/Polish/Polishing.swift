import Foundation

/// On-device transcript cleanup. Mirrors `Transcribing` so
/// `DictationController` and tests treat both model services identically.
protocol Polishing {
    /// Downloads model files if needed, loads them, and warms the pipeline.
    /// Progress in 0...1 (dominated by the one-time download).
    func prepare(progress: @escaping (Double) -> Void) async throws
    /// Releases the model's memory.
    func unload()
    /// Returns the model's cleanup of `text`. The output is raw — callers
    /// validate it with `PolishPrompt.accepted(output:input:)`.
    func polish(_ text: String) async throws -> String
}

enum PolishError: LocalizedError {
    case modelNotLoaded
    case timedOut

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: return "The polish model is not loaded yet."
        case .timedOut: return "Polishing took too long."
        }
    }
}
