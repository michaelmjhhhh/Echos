import Combine
import XCTest
@testable import Echo

@MainActor
final class ModelStoreTests: XCTestCase {
    private var base: URL!
    private var settings: SettingsStore!
    private var downloader: MockDownloader!
    private var cancellables: Set<AnyCancellable> = []

    override func setUp() {
        super.setUp()
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("EchoTests-\(UUID().uuidString)", isDirectory: true)
        settings = SettingsStore(defaults: UserDefaults(suiteName: "EchoTests-\(UUID().uuidString)")!)
        downloader = MockDownloader(downloadBase: base)
        cancellables = []
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: base)
        super.tearDown()
    }

    private func makeStore(downloader: ModelDownloading? = nil) -> ModelStore {
        ModelStore(
            settings: settings,
            downloader: downloader ?? self.downloader,
            downloadBase: base,
            supportedVariants: Set(WhisperModelCatalog.models.map(\.variant))
        )
    }

    // MARK: - Detection

    func testDetectsSeededModelAsDownloaded() throws {
        try makeModelFolder(variant: "openai_whisper-tiny.en", at: base)
        let store = makeStore()
        XCTAssertTrue(store.isDownloaded("openai_whisper-tiny.en"))
        XCTAssertFalse(store.isDownloaded("openai_whisper-base.en"))
    }

    func testPartialFolderIsNotDownloaded() throws {
        try makeModelFolder(variant: "openai_whisper-tiny.en", at: base, missing: "TextDecoder.mlmodelc")
        let store = makeStore()
        XCTAssertFalse(store.isDownloaded("openai_whisper-tiny.en"))
    }

    // MARK: - Download

    func testDownloadMarksVariantDownloadedAndClearsProgress() async {
        let store = makeStore()
        var sawProgress = false
        store.$downloadProgress
            .sink { if $0["openai_whisper-tiny.en"] != nil { sawProgress = true } }
            .store(in: &cancellables)

        await store.download("openai_whisper-tiny.en")

        XCTAssertTrue(sawProgress)
        XCTAssertTrue(store.isDownloaded("openai_whisper-tiny.en"))
        XCTAssertTrue(store.downloadProgress.isEmpty)
        XCTAssertNil(store.lastError)
        XCTAssertEqual(downloader.requestedVariants, ["openai_whisper-tiny.en"])
    }

    func testFailedDownloadSetsLastErrorAndStaysNotDownloaded() async {
        downloader.error = MockDownloadError.network
        let store = makeStore()

        await store.download("openai_whisper-tiny.en")

        XCTAssertNotNil(store.lastError)
        XCTAssertFalse(store.isDownloaded("openai_whisper-tiny.en"))
        XCTAssertTrue(store.downloadProgress.isEmpty)
    }

    func testDownloadSkippedWhenAlreadyDownloaded() async throws {
        try makeModelFolder(variant: "openai_whisper-tiny.en", at: base)
        let store = makeStore()

        await store.download("openai_whisper-tiny.en")

        XCTAssertEqual(downloader.requestedVariants, [])
    }

    func testOnlyOneDownloadRunsAtATime() async {
        let gated = GatedDownloader()
        let store = makeStore(downloader: gated)

        let first = Task { await store.download("openai_whisper-tiny.en") }
        // Let the first download reach the gate before asking for a second.
        var attempts = 0
        while store.downloadProgress.isEmpty && attempts < 10_000 {
            await Task.yield()
            attempts += 1
        }
        guard !store.downloadProgress.isEmpty else {
            gated.release()
            return XCTFail("first download never published progress")
        }

        await store.download("openai_whisper-base.en")
        XCTAssertEqual(gated.started, ["openai_whisper-tiny.en"])

        gated.release()
        await first.value
        XCTAssertTrue(store.downloadProgress.isEmpty)
    }

    // MARK: - Delete

    func testDeleteRemovesFolderAndUpdatesState() throws {
        try makeModelFolder(variant: "openai_whisper-tiny.en", at: base)
        let store = makeStore()
        XCTAssertTrue(store.isDownloaded("openai_whisper-tiny.en"))

        store.delete("openai_whisper-tiny.en")

        XCTAssertFalse(store.isDownloaded("openai_whisper-tiny.en"))
        let folder = WhisperModelPaths.modelFolder(for: "openai_whisper-tiny.en", downloadBase: base)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testDeleteRefusedForActiveVariant() throws {
        settings.modelVariant = "openai_whisper-tiny.en"
        try makeModelFolder(variant: "openai_whisper-tiny.en", at: base)
        let store = makeStore()

        store.delete("openai_whisper-tiny.en")

        XCTAssertTrue(store.isDownloaded("openai_whisper-tiny.en"))
        let folder = WhisperModelPaths.modelFolder(for: "openai_whisper-tiny.en", downloadBase: base)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }
}

// MARK: - Helpers

/// Creates a fake downloaded model folder; pass `missing:` to omit one artifact.
func makeModelFolder(variant: String, at base: URL, missing: String? = nil) throws {
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

private enum MockDownloadError: Error {
    case network
}

/// Emits progress then materializes the model folder, like a real download.
private final class MockDownloader: ModelDownloading, @unchecked Sendable {
    private let downloadBase: URL
    var error: Error?
    private(set) var requestedVariants: [String] = []

    init(downloadBase: URL) {
        self.downloadBase = downloadBase
    }

    func download(variant: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        requestedVariants.append(variant)
        if let error { throw error }
        progress(0.5)
        // Give the main actor a chance to process the progress hop.
        try? await Task.sleep(nanoseconds: 10_000_000)
        progress(1.0)
        try makeModelFolder(variant: variant, at: downloadBase)
    }
}

/// Blocks inside download() until released, to test the serial-download policy.
private final class GatedDownloader: ModelDownloading, @unchecked Sendable {
    private(set) var started: [String] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func download(variant: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        started.append(variant)
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
