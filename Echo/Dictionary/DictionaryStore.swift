import Foundation

/// One dictionary entry: a word Echo should recognize, optionally paired with
/// the misspelling Whisper keeps producing for it.
struct DictionaryEntry: Identifiable, Codable, Equatable {
    let id: UUID
    /// Canonical spelling, exactly as the user wants it typed (≤60 chars).
    var word: String
    /// The misheard version to replace; at most one rule per word.
    var misspelling: String?
    /// Starred words get first claim on the recognition-boost budget.
    var isStarred: Bool
    let dateAdded: Date
}

enum DictionarySort: String, CaseIterable, Identifiable {
    case starredFirst
    case newest
    case oldest
    case alphabetical

    var id: String { rawValue }

    var label: String {
        switch self {
        case .starredFirst: return "Starred first"
        case .newest: return "Newest first"
        case .oldest: return "Oldest first"
        case .alphabetical: return "A–Z"
        }
    }
}

enum DictionaryError: LocalizedError, Equatable {
    case empty
    case tooLong
    case duplicate(existing: String)
    case sameAsWord
    case full

    var errorDescription: String? {
        switch self {
        case .empty: return "Enter a word first."
        case .tooLong: return "Words can be at most \(DictionaryStore.maxWordLength) characters."
        case .duplicate(let existing): return "Already in your dictionary as “\(existing)”."
        case .sameAsWord: return "The misspelling has to differ from the word itself."
        case .full: return "The dictionary is full (\(DictionaryStore.defaultMaxEntries) words). Remove some to add more."
        }
    }
}

/// The user's personal vocabulary, persisted as JSON in Application Support.
/// Feeds two mechanisms: recognition biasing (prompt words) and post-transcription
/// replacement rules. Everything stays on this Mac.
@MainActor
final class DictionaryStore: ObservableObject {
    nonisolated static let maxWordLength = 60
    nonisolated static let defaultMaxEntries = 1000

    @Published private(set) var entries: [DictionaryEntry] = []
    @Published var sort: DictionarySort {
        didSet { defaults.set(sort.rawValue, forKey: Self.sortKey) }
    }

    private let fileURL: URL
    private let maxEntries: Int
    private let defaults: UserDefaults
    private static let sortKey = "dictionarySort"

    init(directory: URL? = nil, maxEntries: Int = DictionaryStore.defaultMaxEntries, defaults: UserDefaults = .standard) {
        self.maxEntries = maxEntries
        self.defaults = defaults
        self.sort = defaults.string(forKey: Self.sortKey)
            .flatMap(DictionarySort.init(rawValue:)) ?? .starredFirst
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Echo", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("dictionary.json")
        load()
    }

    // MARK: - Mutations

    @discardableResult
    func add(word: String, misspelling: String? = nil, starred: Bool = false) -> Result<DictionaryEntry, DictionaryError> {
        switch validate(word: word, misspelling: misspelling, excluding: nil) {
        case .failure(let error): return .failure(error)
        case .success(let clean):
            guard entries.count < maxEntries else { return .failure(.full) }
            let entry = DictionaryEntry(
                id: UUID(),
                word: clean.word,
                misspelling: clean.misspelling,
                isStarred: starred,
                dateAdded: Date()
            )
            entries.insert(entry, at: 0)
            save()
            return .success(entry)
        }
    }

    @discardableResult
    func update(_ entry: DictionaryEntry) -> Result<DictionaryEntry, DictionaryError> {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else {
            // Editing an entry that was deleted underneath the sheet — treat as add.
            return add(word: entry.word, misspelling: entry.misspelling, starred: entry.isStarred)
        }
        switch validate(word: entry.word, misspelling: entry.misspelling, excluding: entry.id) {
        case .failure(let error): return .failure(error)
        case .success(let clean):
            var updated = entries[index]
            updated.word = clean.word
            updated.misspelling = clean.misspelling
            updated.isStarred = entry.isStarred
            entries[index] = updated
            save()
            return .success(updated)
        }
    }

    func delete(_ id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func toggleStar(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].isStarred.toggle()
        save()
    }

    /// Validates and normalizes a prospective word/misspelling pair.
    /// Pass `excluding` when editing so the entry doesn't collide with itself.
    func validate(word: String, misspelling: String?, excluding: UUID?) -> Result<(word: String, misspelling: String?), DictionaryError> {
        let cleanWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanWord.isEmpty else { return .failure(.empty) }
        guard cleanWord.count <= Self.maxWordLength else { return .failure(.tooLong) }
        if let existing = entries.first(where: {
            $0.id != excluding && $0.word.caseInsensitiveCompare(cleanWord) == .orderedSame
        }) {
            return .failure(.duplicate(existing: existing.word))
        }
        var cleanMisspelling = misspelling?.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanMisspelling?.isEmpty == true { cleanMisspelling = nil }
        if let cleanMisspelling {
            guard cleanMisspelling.count <= Self.maxWordLength else { return .failure(.tooLong) }
            guard cleanMisspelling.caseInsensitiveCompare(cleanWord) != .orderedSame else {
                return .failure(.sameAsWord)
            }
        }
        return .success((cleanWord, cleanMisspelling))
    }

    // MARK: - Derived views

    var sortedEntries: [DictionaryEntry] {
        switch sort {
        case .starredFirst:
            // Newest first within each group — entries[] is already newest first.
            return entries.filter(\.isStarred) + entries.filter { !$0.isStarred }
        case .newest:
            return entries
        case .oldest:
            return entries.reversed()
        case .alphabetical:
            return entries.sorted {
                $0.word.localizedCaseInsensitiveCompare($1.word) == .orderedAscending
            }
        }
    }

    var starredCount: Int { entries.filter(\.isStarred).count }
    var replacementCount: Int { entries.filter { $0.misspelling != nil }.count }

    /// Words for the recognition-boost prompt: starred first, then the rest,
    /// each group newest first — the order the token budget is spent in.
    var promptWords: [String] {
        (entries.filter(\.isStarred) + entries.filter { !$0.isStarred }).map(\.word)
    }

    /// Replacement rules, longest misspelling first so overlapping rules
    /// can't clobber each other ("cooper netties" before "cooper").
    var replacementRules: [(misspelling: String, word: String)] {
        entries
            .compactMap { entry in entry.misspelling.map { ($0, entry.word) } }
            .sorted { $0.0.count > $1.0.count }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? decoder.decode([DictionaryEntry].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
