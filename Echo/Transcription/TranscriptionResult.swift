import Foundation

struct TranscriptionRequest: Sendable {
    var vocabulary: [String]
    var language: String?
    var promptTokenBudget: Int
    var temperatureFallbackCount: Int
    /// Recent text dictated just before this audio. Whisper reads the end of
    /// the prompt as preceding speech, which carries names and casing forward.
    var context: String

    init(vocabulary: [String] = [], language: String? = nil, promptTokenBudget: Int = 200,
         temperatureFallbackCount: Int = 5, context: String = "") {
        self.vocabulary = vocabulary
        self.language = language
        self.promptTokenBudget = min(200, max(0, promptTokenBudget))
        self.temperatureFallbackCount = min(5, max(0, temperatureFallbackCount))
        self.context = context
    }
}

/// These are decoder diagnostics, not calibrated confidence probabilities.
/// WhisperKit 0.18 does not provide a usable no-speech probability.
struct TranscriptionDiagnostics: Sendable {
    var recordedDuration: TimeInterval = 0
    var inferenceDuration: TimeInterval = 0
    var decoderDuration: TimeInterval = 0
    var promptDuration: TimeInterval = 0
    var promptTokenCount: Int = 0
    var promptCacheHit: Bool = false
    var encoderRuns: Int = 0
    var decoderTokenCount: Int = 0
    /// Upstream undercounts the first retry and overwrites counts across windows.
    /// Keep its name explicit; never use it as an exact retry count.
    var fallbackCountReported: Int = 0
    var featureDuration: TimeInterval = 0
    var encoderDuration: TimeInterval = 0
    var averageLogProbability: Float?
    var maximumCompressionRatio: Float?
    var isDigitalSilence: Bool = false
}

struct TranscriptionOutput: Sendable {
    var text: String
    var language: String?
    var diagnostics: TranscriptionDiagnostics
    var needsReview: Bool

    init(text: String, language: String? = nil, diagnostics: TranscriptionDiagnostics = .init(), needsReview: Bool = false) {
        self.text = text
        self.language = language
        self.diagnostics = diagnostics
        self.needsReview = needsReview
    }
}
