import Foundation
import WhisperKit
import Hub
import Tokenizers

/// Both startup and the model catalog share this owner. Same-model callers
/// join one task; different-model downloads queue so assets never race repair.
actor ModelAcquisition {
    static let shared = ModelAcquisition()
    private struct Subscriber {
        let continuation: CheckedContinuation<URL, Error>
        let progress: (Double) -> Void
    }
    private struct Acquisition {
        let id: UUID
        let folder: URL
        let task: Task<Void, Never>
        var subscribers: [UUID: Subscriber]
    }
    private var tasks: [String: Acquisition] = [:]
    private var tail: Task<Void, Never>?
    private nonisolated let fileOwnership = ModelFileOwnership()

    func prepare(variant: String, downloadBase: URL?, forceRepair: Bool = false, progress: @escaping (Double) -> Void) async throws -> URL {
        try Task.checkCancellation()
        let folder = WhisperModelPaths.modelFolder(for: variant, downloadBase: downloadBase)
        let regularKey = folder.path
        let repairKey = folder.path + "#repair"
        // A repair queues behind an ordinary in-flight acquisition instead of
        // silently reporting the ordinary download as a completed repair.
        let key = forceRepair || tasks[repairKey] != nil ? repairKey : regularKey
        let subscriberID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                let subscriber = Subscriber(continuation: continuation, progress: progress)
                if tasks[key] != nil {
                    tasks[key]?.subscribers[subscriberID] = subscriber
                    return
                }
                let predecessor = tail
                let operationID = UUID()
                fileOwnership.reserve(folder)
                let task = Task { [self] in
                    await predecessor?.value
                    let result: Result<URL, Error>
                    do {
                        try Task.checkCancellation()
                        let folder = try await Self.install(variant: variant, folder: folder, downloadBase: downloadBase, forceRepair: forceRepair) { value in
                            Task { self.publishProgress(value, key: key, operationID: operationID) }
                        }
                        result = .success(folder)
                    } catch { result = .failure(error) }
                    finish(key: key, operationID: operationID, result: result)
                }
                tasks[key] = Acquisition(id: operationID, folder: folder, task: task, subscribers: [subscriberID: subscriber])
                tail = task
            }
        } onCancel: {
            Task { await self.cancelSubscriber(subscriberID, key: key) }
        }
    }

    private func cancelSubscriber(_ id: UUID, key: String) {
        guard let subscriber = tasks[key]?.subscribers.removeValue(forKey: id) else { return }
        subscriber.continuation.resume(throwing: CancellationError())
        // Acquisition retains ownership and may finish in the background. A
        // retry can join it; no second writer races partially downloaded files.
        // The cancelled caller returns immediately and receives no more progress.
    }

    private func publishProgress(_ value: Double, key: String, operationID: UUID) {
        guard let acquisition = tasks[key], acquisition.id == operationID else { return }
        for subscriber in acquisition.subscribers.values { subscriber.progress(value) }
    }

    private func finish(key: String, operationID: UUID, result: Result<URL, Error>) {
        guard let acquisition = tasks[key], acquisition.id == operationID else { return }
        tasks[key] = nil
        fileOwnership.release(acquisition.folder)
        if tasks.isEmpty { tail = nil }
        for subscriber in acquisition.subscribers.values {
            if case .success = result { subscriber.progress(1) }
            subscriber.continuation.resume(with: result)
        }
    }

    nonisolated func delete(variant: String, downloadBase: URL?) throws {
        try fileOwnership.delete(WhisperModelPaths.modelFolder(for: variant, downloadBase: downloadBase))
    }

    private static func install(variant: String, folder: URL, downloadBase: URL?, forceRepair: Bool, progress: @escaping (Double) -> Void) async throws -> URL {
        guard let tokenizerRepo = WhisperModelCatalog.tokenizerRepository(for: variant) else {
            throw ModelInstallationError.unknownVariant
        }
        let manager = FileManager.default
        if forceRepair, manager.fileExists(atPath: folder.path) {
            // These are reproducible downloaded artifacts, never user data.
            // Remove the entire variant so Hub's file-size cache cannot preserve
            // a corrupt same-size file through an apparent successful repair.
            try manager.removeItem(at: folder)
        }
        if (try? WhisperModelPaths.validateModel(at: folder)) == nil {
            let base = downloadBase ?? WhisperModelPaths.defaultDownloadBase()
            try manager.createDirectory(at: base, withIntermediateDirectories: true)
            if let free = try? base.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
               free < 3_000_000_000 { throw ModelInstallationError.insufficientSpace }
            _ = try await WhisperKit.download(variant: variant, downloadBase: downloadBase) {
                progress($0.fractionCompleted * 0.9)
            }
            try WhisperModelPaths.validateModel(at: folder)
        }
        progress(0.9)
        let localTokenizerValid: Bool
        if WhisperModelPaths.hasTokenizer(at: folder) {
            localTokenizerValid = (try? await AutoTokenizer.from(modelFolder: folder)) != nil
        } else {
            localTokenizerValid = false
        }
        if !localTokenizerValid {
            let hub = HubApi(downloadBase: downloadBase)
            let cached = hub.localRepoLocation(Hub.Repo(id: tokenizerRepo))
            let source: URL
            if !forceRepair, WhisperModelPaths.hasTokenizer(at: cached),
               (try? await AutoTokenizer.from(modelFolder: cached)) != nil {
                source = cached
            } else {
                // Clear only tokenizer metadata when a requested repair or a
                // failed local load proves it cannot be reused.
                if manager.fileExists(atPath: cached.path) { try manager.removeItem(at: cached) }
                source = try await hub.snapshot(from: tokenizerRepo, matching: ["tokenizer.json", "tokenizer_config.json", "config.json", "special_tokens_map.json", "added_tokens.json"])
            }
            for name in ["tokenizer.json", "tokenizer_config.json", "special_tokens_map.json", "added_tokens.json"] {
                let origin = source.appendingPathComponent(name)
                if manager.fileExists(atPath: origin.path) {
                    try Data(contentsOf: origin).write(to: folder.appendingPathComponent(name), options: .atomic)
                }
            }
        }
        // The local-only parser must succeed before "installed" is published.
        _ = try LocalWhisperTokenizer(tokenizer: await AutoTokenizer.from(modelFolder: folder))
        let marker: [String: Any] = ["variant": variant, "repository": WhisperModelPaths.repoID,
                                    "tokenizerRepository": tokenizerRepo, "whisperKitVersion": "0.18.0",
                                    "validatedAt": ISO8601DateFormatter().string(from: Date()), "schema": 1]
        try JSONSerialization.data(withJSONObject: marker, options: [.sortedKeys])
            .write(to: folder.appendingPathComponent("echo-installation.json"), options: .atomic)
        progress(1)
        return folder
    }
}

/// Keeps the synchronous catalog Delete action mutually exclusive with every
/// asynchronous acquisition, including a download whose UI waiter cancelled.
private final class ModelFileOwnership: @unchecked Sendable {
    private let lock = NSLock()
    private var reservations: [URL: Int] = [:]

    func reserve(_ folder: URL) {
        lock.lock()
        defer { lock.unlock() }
        reservations[folder, default: 0] += 1
    }

    func release(_ folder: URL) {
        lock.lock()
        defer { lock.unlock() }
        let remaining = (reservations[folder] ?? 1) - 1
        reservations[folder] = remaining == 0 ? nil : remaining
    }

    func delete(_ folder: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        guard reservations[folder] == nil else { throw ModelInstallationError.acquisitionInProgress }
        try FileManager.default.removeItem(at: folder)
    }
}
