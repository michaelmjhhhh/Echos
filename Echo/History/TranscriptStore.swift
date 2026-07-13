import Foundation

struct TranscriptEntry: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let date: Date
    let text: String

    var wordCount: Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}

/// Local-only dictation history, persisted as JSON in Application Support.
/// Newest entries first, capped so the file can't grow without bound.
@MainActor
final class TranscriptStore: ObservableObject {
    @Published private(set) var entries: [TranscriptEntry] = []

    private let fileURL: URL
    private let maxEntries: Int
    private let persistence: any HistoryPersisting
    private var persistenceRevision = 0
    private var persistenceTask: Task<Void, Never>?

    init(
        directory: URL? = nil,
        maxEntries: Int = 500,
        persistence: (any HistoryPersisting)? = nil
    ) {
        self.maxEntries = maxEntries
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Echo", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let fileURL = base.appendingPathComponent("history.json")
        self.fileURL = fileURL
        self.persistence = persistence ?? HistoryPersistence(fileURL: fileURL)
        load()
    }

    func add(_ text: String) {
        entries.insert(TranscriptEntry(id: UUID(), date: Date(), text: text), at: 0)
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
        scheduleSave()
    }

    func clear() {
        entries = []
        scheduleSave()
    }

    var todayEntries: [TranscriptEntry] {
        entries.filter { Calendar.current.isDateInToday($0.date) }
    }

    var todayWordCount: Int {
        todayEntries.reduce(0) { $0 + $1.wordCount }
    }

    func flushPersistenceForTesting() async {
        await persistenceTask?.value
        await persistence.flush()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? decoder.decode([TranscriptEntry].self, from: data)) ?? []
    }

    private func scheduleSave() {
        persistenceRevision += 1
        let revision = persistenceRevision
        let snapshot = entries
        let previous = persistenceTask
        let persistence = persistence
        persistenceTask = Task {
            await previous?.value
            await persistence.submit(entries: snapshot, revision: revision)
        }
    }
}
