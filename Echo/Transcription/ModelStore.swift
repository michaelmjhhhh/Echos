import Foundation
import WhisperKit

/// Seam so tests never hit the network.
protocol ModelDownloading: Sendable {
    func download(variant: String, progress: @escaping @Sendable (Double) -> Void) async throws
}

struct WhisperKitModelDownloader: ModelDownloading {
    func download(variant: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await WhisperKit.download(variant: variant) { progress($0.fractionCompleted) }
    }
}

/// Filesystem truth for the model catalog: which variants are on disk,
/// downloads with progress, deletion. Activating a model is
/// DictationController's job, not this store's.
@MainActor
final class ModelStore: ObservableObject {
    @Published private(set) var downloadedVariants: Set<String> = []
    @Published private(set) var downloadProgress: [String: Double] = [:]
    @Published private(set) var lastError: String?

    let catalog = WhisperModelCatalog.models
    let supportedVariants: Set<String>

    private let settings: SettingsStore
    private let downloader: ModelDownloading
    private let downloadBase: URL?

    init(
        settings: SettingsStore = .shared,
        downloader: ModelDownloading = WhisperKitModelDownloader(),
        downloadBase: URL? = nil,
        supportedVariants: Set<String>? = nil
    ) {
        self.settings = settings
        self.downloader = downloader
        self.downloadBase = downloadBase
        self.supportedVariants = supportedVariants ?? Set(WhisperKit.recommendedModels().supported)
        refresh()
    }

    var isDownloadingAnything: Bool { !downloadProgress.isEmpty }

    func isDownloaded(_ variant: String) -> Bool {
        downloadedVariants.contains(variant)
    }

    /// Rescans only catalog variants — never enumerates the repo folder,
    /// which also holds HubApi's `.cache/` metadata.
    func refresh() {
        downloadedVariants = Set(
            catalog.map(\.variant).filter { WhisperModelPaths.isDownloaded($0, downloadBase: downloadBase) }
        )
    }

    /// Serial policy: one download at a time keeps bandwidth and the UI simple.
    func download(_ variant: String) async {
        guard downloadProgress.isEmpty, !isDownloaded(variant) else { return }
        downloadProgress[variant] = 0
        lastError = nil
        defer { downloadProgress[variant] = nil }
        do {
            try await downloader.download(variant: variant) { progress in
                Task { @MainActor [weak self] in
                    guard let self, self.downloadProgress[variant] != nil else { return }
                    self.downloadProgress[variant] = progress
                }
            }
            refresh()
        } catch {
            // Partial files stay on disk — HubApi resumes them on retry.
            lastError = "Download failed: \(error.localizedDescription)"
        }
    }

    func delete(_ variant: String) {
        // Backstop — the UI never offers deleting the active model.
        guard variant != settings.modelVariant else { return }
        do {
            try FileManager.default.removeItem(
                at: WhisperModelPaths.modelFolder(for: variant, downloadBase: downloadBase)
            )
        } catch {
            lastError = "Couldn't delete model: \(error.localizedDescription)"
        }
        refresh()
    }
}
