import Foundation
import OSLog

protocol HistoryPersisting: Sendable {
    func submit(entries: [TranscriptEntry], revision: Int) async
    func submit(entries: [TranscriptEntry], revision: Int, preservePrevious: Bool, clearBackup: Bool, purgeRecovery: Bool) async
    func flush() async
    func lastError() async -> StorePersistenceError?
}

extension HistoryPersisting {
    func submit(entries: [TranscriptEntry], revision: Int, preservePrevious: Bool, clearBackup: Bool, purgeRecovery: Bool) async {
        await submit(entries: entries, revision: revision)
    }
    func lastError() async -> StorePersistenceError? { nil }
}

/// Serializes immutable snapshots away from the insertion path. Callers await the
/// store's flush on normal termination and explicit deletion, and surface errors.
actor HistoryPersistence: HistoryPersisting {
    private static let logger = Logger(subsystem: "com.michael.echo", category: "history-persistence")
    private static let signposter = OSSignposter(logger: logger)
    private let file: StoreFile<[TranscriptEntry]>
    private var newestPersistedRevision = 0
    private var error: StorePersistenceError?

    init(fileURL: URL) { file = StoreFile(url: fileURL) }

    func submit(entries: [TranscriptEntry], revision: Int) async {
        await submit(entries: entries, revision: revision, preservePrevious: true, clearBackup: entries.isEmpty, purgeRecovery: entries.isEmpty)
    }

    func submit(entries: [TranscriptEntry], revision: Int, preservePrevious: Bool, clearBackup: Bool, purgeRecovery: Bool) async {
        guard revision > newestPersistedRevision else { return }
        do {
            try Self.signposter.withIntervalSignpost("Persist history") {
                try file.save(entries, preservePrevious: preservePrevious, clearBackup: clearBackup, purgeRecovery: purgeRecovery)
            }
            newestPersistedRevision = revision
            error = nil
        } catch {
            self.error = (error as? StorePersistenceError) ?? .writeFailed(error.localizedDescription)
            Self.logger.error("History persistence failed at revision \(revision, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func flush() async {}
    func lastError() async -> StorePersistenceError? { error }
}
