import Foundation

struct TranscriptEntry: Identifiable, Codable, Equatable {
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

    init(directory: URL? = nil, maxEntries: Int = 500) {
        self.maxEntries = maxEntries
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Echo", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("history.json")
        load()
    }

    func add(_ text: String) {
        entries.insert(TranscriptEntry(id: UUID(), date: Date(), text: text), at: 0)
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    var todayEntries: [TranscriptEntry] {
        entries.filter { Calendar.current.isDateInToday($0.date) }
    }

    var todayWordCount: Int {
        todayEntries.reduce(0) { $0 + $1.wordCount }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? decoder.decode([TranscriptEntry].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
