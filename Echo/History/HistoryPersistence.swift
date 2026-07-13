import Foundation

protocol HistoryPersisting: Sendable {
    func submit(entries: [TranscriptEntry], revision: Int) async
    func flush() async
}

/// Serializes immutable history snapshots away from the main actor.
actor HistoryPersistence: HistoryPersisting {
    private let fileURL: URL
    private var newestPersistedRevision = 0

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func submit(entries: [TranscriptEntry], revision: Int) async {
        guard revision > newestPersistedRevision else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
            newestPersistedRevision = revision
        } catch {
            // History is best effort. A later complete snapshot may succeed.
        }
    }

    func flush() async {}
}
