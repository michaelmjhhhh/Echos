import Foundation

/// One entry in Echo's curated speech-model catalog.
struct WhisperModel: Identifiable, Equatable {
    /// Exact folder name in the argmaxinc/whisperkit-coreml repo.
    let variant: String
    let displayName: String
    let sizeLabel: String
    let detail: String

    var id: String { variant }
}

enum WhisperModelCatalog {
    static let models: [WhisperModel] = [
        WhisperModel(
            variant: "openai_whisper-tiny.en",
            displayName: "Tiny (English)",
            sizeLabel: "~75 MB",
            detail: "Fastest, least accurate"
        ),
        WhisperModel(
            variant: "openai_whisper-base.en",
            displayName: "Base (English)",
            sizeLabel: "~145 MB",
            detail: "Fast, good for quick notes"
        ),
        WhisperModel(
            variant: "openai_whisper-small.en",
            displayName: "Small (English)",
            sizeLabel: "~485 MB",
            detail: "Balanced speed and accuracy"
        ),
        WhisperModel(
            variant: "distil-whisper_distil-large-v3_594MB",
            displayName: "Distil Large v3",
            sizeLabel: "594 MB",
            detail: "Echo's default — accurate and quick"
        ),
        WhisperModel(
            variant: "openai_whisper-large-v3-v20240930_626MB",
            displayName: "Large v3 Turbo",
            sizeLabel: "626 MB",
            detail: "High accuracy, near-turbo speed"
        ),
        WhisperModel(
            variant: "openai_whisper-large-v3_947MB",
            displayName: "Large v3",
            sizeLabel: "947 MB",
            detail: "Most accurate, slowest"
        ),
    ]

    static func model(for variant: String) -> WhisperModel? {
        models.first { $0.variant == variant }
    }

    /// Distil Large v3 uses a multilingual tokenizer but is trained for English.
    /// Tokenizer capacity alone must not advertise multilingual recognition.
    static func supportsMultilingual(_ variant: String) -> Bool {
        variant.hasPrefix("openai_whisper-large-v3")
    }

    static func tokenizerRepository(for variant: String) -> String? {
        switch variant {
        case "openai_whisper-tiny.en": return "openai/whisper-tiny.en"
        case "openai_whisper-base.en": return "openai/whisper-base.en"
        case "openai_whisper-small.en": return "openai/whisper-small.en"
        case "distil-whisper_distil-large-v3_594MB", "openai_whisper-large-v3-v20240930_626MB", "openai_whisper-large-v3_947MB":
            return "openai/whisper-large-v3"
        default: return nil
        }
    }

    /// Falls back to the raw variant string for unknown/legacy values.
    static func displayName(for variant: String) -> String {
        model(for: variant)?.displayName ?? variant
    }
}

/// Filesystem layout of WhisperKit/HubApi downloads:
/// `<downloadBase>/models/argmaxinc/whisperkit-coreml/<variant>/`
enum WhisperModelPaths {
    static let repoID = "argmaxinc/whisperkit-coreml"

    private static let requiredArtifacts = [
        "config.json",
        "AudioEncoder.mlmodelc",
        "TextDecoder.mlmodelc",
        "MelSpectrogram.mlmodelc",
    ]

    static func defaultDownloadBase() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("huggingface")
    }

    static func modelFolder(for variant: String, downloadBase: URL?) -> URL {
        (downloadBase ?? defaultDownloadBase())
            .appendingPathComponent("models")
            .appendingPathComponent(repoID)
            .appendingPathComponent(variant)
    }

    static func isDownloaded(_ variant: String, downloadBase: URL?) -> Bool {
        let folder = modelFolder(for: variant, downloadBase: downloadBase)
        return (try? validateModel(at: folder)) != nil && localTokenizerFolder(for: variant, downloadBase: downloadBase) != nil
    }

    /// Older Echo installations keep the tokenizer in Hub's shared cache.
    /// Reuse those assets offline without forcing an otherwise needless download.
    static func localTokenizerFolder(for variant: String, downloadBase: URL?) -> URL? {
        let bundled = modelFolder(for: variant, downloadBase: downloadBase)
        if hasTokenizer(at: bundled) { return bundled }
        guard let repo = WhisperModelCatalog.tokenizerRepository(for: variant) else { return nil }
        let cached = (downloadBase ?? defaultDownloadBase()).appendingPathComponent("models").appendingPathComponent(repo)
        return hasTokenizer(at: cached) ? cached : nil
    }

    /// A cheap structural check, run during setup/catalog refresh, not dictation.
    /// Actual CoreML and tokenizer loading remain the activation readiness gate.
    static func validateModel(at folder: URL) throws {
        let manager = FileManager.default
        let config = folder.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: config),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              !object.isEmpty else { throw ModelInstallationError.invalidAssets("config.json") }
        for artifact in requiredArtifacts where artifact != "config.json" {
            let url = folder.appendingPathComponent(artifact)
            var directory: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue,
                  let enumerator = manager.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]),
                  enumerator.contains(where: { entry in
                      guard let file = entry as? URL,
                            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else { return false }
                      return values.isRegularFile == true && (values.fileSize ?? 0) > 0
                  }) else { throw ModelInstallationError.invalidAssets(artifact) }
        }
    }

    static func hasTokenizer(at folder: URL) -> Bool {
        ["tokenizer.json", "tokenizer_config.json"].allSatisfy { name in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return !object.isEmpty
        }
    }
}

enum ModelInstallationError: LocalizedError {
    case invalidAssets(String)
    case unknownVariant
    case insufficientSpace
    case acquisitionInProgress

    var errorDescription: String? {
        switch self {
        case .invalidAssets(let name): return "The model installation is incomplete or damaged (\(name)). Use Repair model to download a clean copy."
        case .unknownVariant: return "This model variant is not in Echo's supported catalog. Select a supported model."
        case .acquisitionInProgress: return "The model is still being installed. Wait for installation to finish before deleting it."
        case .insufficientSpace: return "There is not enough free disk space to install the model. Free at least 3 GB and retry."
        }
    }
}
