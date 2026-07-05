import Foundation
import WhisperKit

protocol Transcribing {
    /// Downloads model files if needed, reporting progress in 0...1.
    func prepare(progress: @escaping (Double) -> Void) async throws
    /// Loads the (already downloaded) model into memory.
    func loadModel() async throws
    /// `vocabulary` is the user's dictionary in priority order; implementations
    /// use it to bias recognition toward those spellings.
    func transcribe(_ samples: [Float], vocabulary: [String]) async throws -> String
}

/// Wraps WhisperKit: downloads the CoreML model on first launch, then
/// transcribes 16 kHz mono Float32 sample buffers on-device.
final class TranscriptionService: Transcribing {
    private let modelVariant: String
    /// nil = HubApi's default (~/Documents/huggingface); injectable for tests.
    private let downloadBase: URL?
    private(set) var modelFolder: URL?
    private var whisperKit: WhisperKit?

    init(modelVariant: String, downloadBase: URL? = nil) {
        self.modelVariant = modelVariant
        self.downloadBase = downloadBase
    }

    func prepare(progress: @escaping (Double) -> Void) async throws {
        // Already on disk → prepare locally so switching to a downloaded
        // model (and reverting after a failed switch) works offline.
        if WhisperModelPaths.isDownloaded(modelVariant, downloadBase: downloadBase) {
            modelFolder = WhisperModelPaths.modelFolder(for: modelVariant, downloadBase: downloadBase)
            progress(1)
            return
        }
        modelFolder = try await WhisperKit.download(variant: modelVariant, downloadBase: downloadBase) { downloadProgress in
            progress(downloadProgress.fractionCompleted)
        }
    }

    func loadModel() async throws {
        let config = WhisperKitConfig(
            model: modelVariant,
            modelFolder: modelFolder?.path,
            prewarm: true,
            load: true,
            download: false
        )
        let kit = try await WhisperKit(config)
        whisperKit = kit

        // One throwaway inference so the whole pipeline (feature extractor,
        // decoder loop, tokenizer, memory pools) is warm before the app
        // reports ready — otherwise the first real dictation pays a 2–5 s
        // cold start. Failure here must never fail loading.
        _ = try? await kit.transcribe(
            audioArray: [Float](repeating: 0, count: 1600), // 0.1 s of silence
            decodeOptions: DecodingOptions(task: .transcribe, language: "en", skipSpecialTokens: true)
        )
    }

    func transcribe(_ samples: [Float], vocabulary: [String]) async throws -> String {
        guard let whisperKit else {
            throw TranscriptionError.modelNotLoaded
        }
        var options = DecodingOptions(
            task: .transcribe,
            language: "en",
            skipSpecialTokens: true
        )
        applyVocabulary(vocabulary, to: &options)
        let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
        return results.map(\.text).joined(separator: " ")
    }

    /// Feeds the dictionary as a prompt (Whisper's "previous context") so
    /// decoding is biased toward the user's spellings.
    private func applyVocabulary(_ vocabulary: [String], to options: inout DecodingOptions) {
        guard !vocabulary.isEmpty, let tokenizer = whisperKit?.tokenizer else { return }
        let promptText = VocabularyPrompt.text(for: vocabulary) { candidate in
            tokenizer.encode(text: " " + candidate).count
        }
        guard !promptText.isEmpty else { return }
        options.promptTokens = tokenizer.encode(text: " " + promptText)
            .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        options.usePrefillPrompt = true
    }
}

enum TranscriptionError: LocalizedError {
    case modelNotLoaded

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: return "The speech model is not loaded yet."
        }
    }
}
