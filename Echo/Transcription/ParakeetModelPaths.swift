import Foundation
import FluidAudio

/// Parakeet TDT 0.6B v2 (English) through FluidAudio. Files keep FluidAudio's
/// layout: `<base>/parakeet-tdt-0.6b-v2-coreml/` holds the preprocessor,
/// encoder, decoder, joint network and vocabulary (about 465 MB).
enum ParakeetModelPaths {
    static let variant = "parakeet-tdt-0.6b-v2"
    static let version: AsrModelVersion = .v2

    /// FluidAudio's default is `~/Library/Application Support/FluidAudio/Models/`.
    /// A custom download base (tests, EchoEvaluate) keeps the same repo folder name.
    static func folder(downloadBase: URL?) -> URL {
        let standard = AsrModels.defaultCacheDirectory(for: version)
        guard let downloadBase else { return standard }
        return downloadBase.appendingPathComponent("models").appendingPathComponent(standard.lastPathComponent)
    }

    static func isInstalled(at folder: URL) -> Bool {
        AsrModels.modelsExist(at: folder, version: version)
    }

    static func install(folder: URL, forceRepair: Bool, progress: @escaping (Double) -> Void) async throws -> URL {
        let manager = FileManager.default
        if forceRepair, manager.fileExists(atPath: folder.path) {
            try manager.removeItem(at: folder)
        }
        if !isInstalled(at: folder) {
            let parent = folder.deletingLastPathComponent()
            try manager.createDirectory(at: parent, withIntermediateDirectories: true)
            if let free = try? parent.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
               free < 3_000_000_000 { throw ModelInstallationError.insufficientSpace }
            _ = try await AsrModels.download(to: folder, version: version) { progress($0.fractionCompleted * 0.99) }
        }
        guard isInstalled(at: folder) else { throw ModelInstallationError.invalidAssets("Parakeet model files") }
        progress(1)
        return folder
    }
}
