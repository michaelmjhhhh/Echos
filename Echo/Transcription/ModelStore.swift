import Foundation
import WhisperKit

/// Seam so tests never hit the network.
protocol ModelDownloading: Sendable {
    func download(variant: String, progress: @escaping @Sendable (Double) -> Void) async throws
}

struct WhisperKitModelDownloader: ModelDownloading {
    var downloadBase: URL? = nil

    func download(variant: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await ModelAcquisition.shared.prepare(variant: variant, downloadBase: downloadBase, progress: progress)
    }
}

enum ModelInstallationState: Equatable {
    case notInstalled
    case downloading
    case validating
    case installed
    case failed(String)
}

/// Filesystem truth for the model catalog: which variants are on disk,
/// downloads with progress, deletion. Activating a model is
/// DictationController's job, not this store's.
@MainActor
final class ModelStore: ObservableObject {
    @Published private(set) var downloadedVariants: Set<String> = []
    @Published private(set) var downloadProgress: [String: Double] = [:]
    @Published private(set) var lastError: String?
    @Published private(set) var installationStates: [String: ModelInstallationState] = [:]

    let catalog = WhisperModelCatalog.models
    let supportedVariants: Set<String>

    private let settings: SettingsStore
    private let downloader: ModelDownloading
    private let downloadBase: URL?

    init(
        settings: SettingsStore? = nil,
        downloader: ModelDownloading? = nil,
        downloadBase: URL? = nil,
        supportedVariants: Set<String>? = nil
    ) {
        self.settings = settings ?? .shared
        self.downloader = downloader ?? WhisperKitModelDownloader(downloadBase: downloadBase)
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
        for model in catalog where downloadProgress[model.variant] == nil {
            if downloadedVariants.contains(model.variant) { installationStates[model.variant] = .installed }
            else if case .failed = installationStates[model.variant] {} // Preserve actionable failure.
            else { installationStates[model.variant] = .notInstalled }
        }
    }

    /// Serial policy: one download at a time keeps bandwidth and the UI simple.
    func download(_ variant: String) async {
        guard downloadProgress.isEmpty, !isDownloaded(variant) else { return }
        downloadProgress[variant] = 0
        installationStates[variant] = .downloading
        lastError = nil
        defer { downloadProgress[variant] = nil }
        do {
            try await downloader.download(variant: variant) { progress in
                Task { @MainActor [weak self] in
                    guard let self, self.downloadProgress[variant] != nil else { return }
                    self.downloadProgress[variant] = progress
                    self.installationStates[variant] = progress >= 0.9 ? .validating : .downloading
                }
            }
            refresh()
            guard isDownloaded(variant) else { throw ModelInstallationError.invalidAssets("model or tokenizer") }
            installationStates[variant] = .installed
        } catch {
            // Partial files stay on disk — HubApi resumes them on retry.
            lastError = "Download failed: \(error.localizedDescription)"
            installationStates[variant] = .failed(error.localizedDescription)
        }
    }

    /// Active-model repair is coordinated by the controller, which unloads it
    /// first. This action repairs inactive installations from the model list.
    func repair(_ variant: String) async {
        guard variant != settings.modelVariant, !isDownloadingAnything else { return }
        downloadProgress[variant] = 0
        installationStates[variant] = .downloading
        lastError = nil
        defer { downloadProgress[variant] = nil; refresh() }
        do {
            _ = try await ModelAcquisition.shared.prepare(variant: variant, downloadBase: downloadBase, forceRepair: true) { progress in
                Task { @MainActor [weak self] in
                    guard let self, self.downloadProgress[variant] != nil else { return }
                    self.downloadProgress[variant] = progress
                    self.installationStates[variant] = progress >= 0.9 ? .validating : .downloading
                }
            }
        } catch {
            lastError = "Repair failed: \(error.localizedDescription)"
            installationStates[variant] = .failed(error.localizedDescription)
        }
    }

    func delete(_ variant: String) {
        // Backstop — the UI never offers deleting the active model.
        guard variant != settings.modelVariant, !isDownloadingAnything else { return }
        do {
            try ModelAcquisition.shared.delete(variant: variant, downloadBase: downloadBase)
        } catch {
            lastError = "Couldn't delete model: \(error.localizedDescription)"
        }
        refresh()
    }
}
