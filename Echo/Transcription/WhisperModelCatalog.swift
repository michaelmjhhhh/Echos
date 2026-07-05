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

    /// Falls back to the raw variant string for unknown/legacy values.
    static func displayName(for variant: String) -> String {
        model(for: variant)?.displayName ?? variant
    }
}

/// Filesystem layout of WhisperKit/HubApi downloads:
/// `<downloadBase>/models/argmaxinc/whisperkit-coreml/<variant>/`
enum WhisperModelPaths {
    static let repoID = "argmaxinc/whisperkit-coreml"

    /// A complete model folder contains all of these; anything less is a
    /// partial download (HubApi moves each file into place atomically, so
    /// presence means complete).
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
        return requiredArtifacts.allSatisfy {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
    }
}
