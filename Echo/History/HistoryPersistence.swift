import Foundation
import OSLog

protocol HistoryPersisting: Sendable {
    func submit(entries: [TranscriptEntry], revision: Int) async
    func flush() async
}

/// Serializes immutable history snapshots away from the main actor.
actor HistoryPersistence: HistoryPersisting {
    private static let logger = Logger(subsystem: "com.michael.echo", category: "history-persistence")
    private static let signposter = OSSignposter(logger: logger)

    private let fileURL: URL
    private var newestPersistedRevision = 0

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func submit(entries: [TranscriptEntry], revision: Int) async {
        guard revision > newestPersistedRevision else { return }
        do {
            try Self.signposter.withIntervalSignpost("Persist history") {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(entries)
                try data.write(to: fileURL, options: .atomic)
            }
            newestPersistedRevision = revision
        } catch {
            Self.logger.error(
                "History persistence failed at revision \(revision, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            // History is best effort. A later complete snapshot may succeed.
        }
    }

    func flush() async {}
}
