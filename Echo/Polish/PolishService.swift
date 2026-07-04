import Foundation
import MLXLLM
import MLXLMCommon

/// Wraps mlx-swift-lm: downloads a small instruct model from Hugging Face on
/// first enable, then rewrites transcripts on-device. Each polish call uses a
/// fresh ChatSession so no history leaks between dictations, and greedy
/// decoding keeps results deterministic.
///
/// Note: `MLXLMCommon`'s `loadContainer` bundles Hugging Face downloading and
/// tokenizer loading internally (via its own `Hub`/`Tokenizers` dependencies)
/// — there are no separate `MLXLMHuggingFace`/`MLXLMTokenizers` products to
/// import in this package version, unlike an earlier draft of this file.
final class PolishService: Polishing {
    /// ~1B-class 4-bit instruct model (~0.7 GB download, ~1 GB resident).
    /// Swappable the same way `SettingsStore.defaultModelVariant` is.
    static let defaultModelID = "mlx-community/Llama-3.2-1B-Instruct-4bit"

    private let modelID: String
    private var container: ModelContainer?

    init(modelID: String = PolishService.defaultModelID) {
        self.modelID = modelID
    }

    func prepare(progress: @escaping (Double) -> Void) async throws {
        let container = try await LLMModelFactory.shared.loadContainer(
            configuration: .init(id: modelID),
            progressHandler: { downloadProgress in
                progress(downloadProgress.fractionCompleted)
            }
        )
        self.container = container
        // One throwaway generation so the first real polish doesn't pay the
        // cold start — mirrors TranscriptionService.loadModel(). Failure here
        // must never fail preparation.
        _ = try? await ChatSession(
            container,
            instructions: PolishPrompt.instructions,
            generateParameters: GenerateParameters(maxTokens: 8, temperature: 0)
        ).respond(to: "Okay.")
    }

    func unload() {
        container = nil // releasing the last reference frees the model memory
    }

    func polish(_ text: String) async throws -> String {
        guard let container else { throw PolishError.modelNotLoaded }
        let session = ChatSession(
            container,
            instructions: PolishPrompt.instructions,
            generateParameters: GenerateParameters(
                maxTokens: PolishPrompt.maxTokens(for: text),
                temperature: 0 // greedy: same input, same output
            )
        )
        return try await session.respond(to: text)
    }
}
