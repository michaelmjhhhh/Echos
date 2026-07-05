import XCTest
@testable import Echo

final class WhisperModelCatalogTests: XCTestCase {
    private var base: URL!

    override func setUp() {
        super.setUp()
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("EchoTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: base)
        super.tearDown()
    }

    // MARK: - Catalog contents

    func testCatalogVariantsAreUnique() {
        let variants = WhisperModelCatalog.models.map(\.variant)
        XCTAssertEqual(variants.count, Set(variants).count)
        XCTAssertGreaterThanOrEqual(variants.count, 5)
    }

    func testCatalogContainsEchoDefaultModel() {
        XCTAssertTrue(
            WhisperModelCatalog.models.contains { $0.variant == SettingsStore.defaultModelVariant },
            "The curated catalog must include Echo's default variant"
        )
    }

    func testKnownVariantsHaveFriendlyNames() {
        XCTAssertEqual(WhisperModelCatalog.model(for: "openai_whisper-base.en")?.displayName, "Base (English)")
        XCTAssertEqual(
            WhisperModelCatalog.model(for: SettingsStore.defaultModelVariant)?.displayName,
            "Distil Large v3"
        )
    }

    func testDisplayNameFallsBackToRawVariantForUnknownModels() {
        XCTAssertEqual(WhisperModelCatalog.displayName(for: "somebody_custom-model"), "somebody_custom-model")
    }

    // MARK: - Filesystem layout

    func testModelFolderMirrorsHubApiLayout() {
        let folder = WhisperModelPaths.modelFolder(for: "openai_whisper-tiny.en", downloadBase: base)
        XCTAssertEqual(
            folder.path,
            base.appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-tiny.en").path
        )
    }

    func testDefaultDownloadBaseIsDocumentsHuggingface() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        XCTAssertEqual(
            WhisperModelPaths.defaultDownloadBase().path,
            documents.appendingPathComponent("huggingface").path
        )
    }

    // MARK: - isDownloaded

    func testIsDownloadedFalseWhenFolderMissing() {
        XCTAssertFalse(WhisperModelPaths.isDownloaded("openai_whisper-tiny.en", downloadBase: base))
    }

    func testIsDownloadedFalseForPartialDownload() throws {
        try makeModelFolder(variant: "openai_whisper-tiny.en", missing: "TextDecoder.mlmodelc")
        XCTAssertFalse(WhisperModelPaths.isDownloaded("openai_whisper-tiny.en", downloadBase: base))
    }

    func testIsDownloadedTrueWhenAllArtifactsPresent() throws {
        try makeModelFolder(variant: "openai_whisper-tiny.en")
        XCTAssertTrue(WhisperModelPaths.isDownloaded("openai_whisper-tiny.en", downloadBase: base))
    }

    // MARK: - Helpers

    /// Creates a fake downloaded model folder; pass `missing:` to omit one artifact.
    private func makeModelFolder(variant: String, missing: String? = nil) throws {
        let folder = WhisperModelPaths.modelFolder(for: variant, downloadBase: base)
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for artifact in ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"]
        where artifact != missing {
            try fm.createDirectory(at: folder.appendingPathComponent(artifact), withIntermediateDirectories: true)
        }
        if missing != "config.json" {
            try Data("{}".utf8).write(to: folder.appendingPathComponent("config.json"))
        }
    }
}
