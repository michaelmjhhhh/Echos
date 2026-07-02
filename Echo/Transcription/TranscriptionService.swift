import Foundation
import WhisperKit

protocol Transcribing {
    /// Downloads model files if needed, reporting progress in 0...1.
    func prepare(progress: @escaping (Double) -> Void) async throws
    /// Loads the (already downloaded) model into memory.
    func loadModel() async throws
    func transcribe(_ samples: [Float]) async throws -> String
}

/// Wraps WhisperKit: downloads the CoreML model on first launch, then
/// transcribes 16 kHz mono Float32 sample buffers on-device.
final class TranscriptionService: Transcribing {
    private let modelVariant: String
    private var modelFolder: URL?
    private var whisperKit: WhisperKit?

    init(modelVariant: String) {
        self.modelVariant = modelVariant
    }

    func prepare(progress: @escaping (Double) -> Void) async throws {
        modelFolder = try await WhisperKit.download(variant: modelVariant) { downloadProgress in
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

    func transcribe(_ samples: [Float]) async throws -> String {
        guard let whisperKit else {
            throw TranscriptionError.modelNotLoaded
        }
        let options = DecodingOptions(
            task: .transcribe,
            language: "en",
            skipSpecialTokens: true
        )
        let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
        return results.map(\.text).joined(separator: " ")
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
