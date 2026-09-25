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
    var allowProtectedText: Bool

    init(id: UUID, word: String, misspelling: String?, isStarred: Bool, dateAdded: Date, allowProtectedText: Bool = false) {
        self.id = id
        self.word = word
        self.misspelling = misspelling
        self.isStarred = isStarred
        self.dateAdded = dateAdded
        self.allowProtectedText = allowProtectedText
    }

    private enum CodingKeys: String, CodingKey { case id, word, misspelling, isStarred, dateAdded, allowProtectedText }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        word = try values.decode(String.self, forKey: .word)
        misspelling = try values.decodeIfPresent(String.self, forKey: .misspelling)
        isStarred = try values.decode(Bool.self, forKey: .isStarred)
        dateAdded = try values.decode(Date.self, forKey: .dateAdded)
        allowProtectedText = try values.decodeIfPresent(Bool.self, forKey: .allowProtectedText) ?? false
    }
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
    case aliasConflict(existing: String)
    case persistence(String)

    var errorDescription: String? {
        switch self {
        case .empty: return "Enter a word first."
        case .tooLong: return "Words can be at most \(DictionaryStore.maxWordLength) characters."
        case .duplicate(let existing): return "Already in your dictionary as “\(existing)”."
        case .sameAsWord: return "The misspelling has to differ from the word itself."
        case .aliasConflict(let existing): return "This misspelling is already used for “\(existing)”."
        case .persistence(let message): return message
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
    @Published private(set) var persistenceError: StorePersistenceError?
    @Published private(set) var isSaving = false
    @Published private(set) var recoveryAvailable = false
    private var loadBlocked = false
    private var recovered = false
    private var pendingEntries: [DictionaryEntry]?
    private(set) var compiledReplacementRules: [CompiledReplacementRule] = []
    @Published var sort: DictionarySort {
        didSet { defaults.set(sort.rawValue, forKey: Self.sortKey) }
    }

    private let fileURL: URL
    private let maxEntries: Int
    private let defaults: UserDefaults
    private static let sortKey = "dictionarySort"

    init(directory: URL? = nil, maxEntries: Int = DictionaryStore.defaultMaxEntries, defaults: UserDefaults = .standard) {
        self.maxEntries = max(0, maxEntries)
        self.defaults = defaults
        self.sort = defaults.string(forKey: Self.sortKey)
            .flatMap(DictionarySort.init(rawValue:)) ?? .starredFirst
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Echo", isDirectory: true)
        fileURL = base.appendingPathComponent("dictionary.json")
        load()
        rebuildCompiledReplacementRules()
    }

    // MARK: - Mutations

    @discardableResult
    func add(word: String, misspelling: String? = nil, starred: Bool = false, allowProtectedText: Bool = false) -> Result<DictionaryEntry, DictionaryError> {
        switch validate(word: word, misspelling: misspelling, excluding: nil) {
        case .failure(let error): return .failure(error)
        case .success(let clean):
            guard entries.count < maxEntries else { return .failure(.full) }
            let entry = DictionaryEntry(
                id: UUID(),
                word: clean.word,
                misspelling: clean.misspelling,
                isStarred: starred,
                dateAdded: Date(),
                allowProtectedText: allowProtectedText
            )
            var candidate = entries
            candidate.insert(entry, at: 0)
            guard commit(candidate) else { return .failure(.persistence(persistenceError!.localizedDescription)) }
            return .success(entry)
        }
    }

    @discardableResult
    func update(_ entry: DictionaryEntry) -> Result<DictionaryEntry, DictionaryError> {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else {
            // Editing an entry that was deleted underneath the sheet — treat as add.
            return add(word: entry.word, misspelling: entry.misspelling, starred: entry.isStarred, allowProtectedText: entry.allowProtectedText)
        }
        switch validate(word: entry.word, misspelling: entry.misspelling, excluding: entry.id) {
        case .failure(let error): return .failure(error)
        case .success(let clean):
            var updated = entries[index]
            updated.word = clean.word
            updated.misspelling = clean.misspelling
            updated.isStarred = entry.isStarred
            updated.allowProtectedText = entry.allowProtectedText
            var candidate = entries
            candidate[index] = updated
            guard commit(candidate) else { return .failure(.persistence(persistenceError!.localizedDescription)) }
            return .success(updated)
        }
    }

    @discardableResult
    func delete(_ id: UUID) -> Bool { commit(entries.filter { $0.id != id }) }

    @discardableResult
    func toggleStar(_ id: UUID) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        var candidate = entries
        candidate[index].isStarred.toggle()
        return commit(candidate)
    }

    /// One validated mutation and one disk write, including imports into an empty dictionary.
    @discardableResult
    func importWords(_ words: [String]) -> Result<Int, DictionaryError> {
        var candidate = entries
        var known = Set(entries.map { TextRuleMatcher.key($0.word) })
        var added = 0
        for word in words {
            let clean = TextRuleMatcher.normalized(word.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !clean.isEmpty else { continue }
            guard clean.count <= Self.maxWordLength else { return .failure(.tooLong) }
            guard known.insert(TextRuleMatcher.key(clean)).inserted else { continue }
            guard candidate.count < maxEntries else { return .failure(.full) }
            candidate.insert(DictionaryEntry(id: UUID(), word: clean, misspelling: nil, isStarred: false, dateAdded: Date()), at: 0)
            added += 1
        }
        guard added > 0 else { return .success(0) }
        guard commit(candidate) else { return .failure(.persistence(persistenceError!.localizedDescription)) }
        return .success(added)
    }

    /// Validates and normalizes a prospective word/misspelling pair.
    /// Pass `excluding` when editing so the entry doesn't collide with itself.
    func validate(word: String, misspelling: String?, excluding: UUID?) -> Result<(word: String, misspelling: String?), DictionaryError> {
        let cleanWord = TextRuleMatcher.normalized(word.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !cleanWord.isEmpty else { return .failure(.empty) }
        guard cleanWord.count <= Self.maxWordLength else { return .failure(.tooLong) }
        if let existing = entries.first(where: {
            $0.id != excluding && TextRuleMatcher.key($0.word) == TextRuleMatcher.key(cleanWord)
        }) {
            return .failure(.duplicate(existing: existing.word))
        }
        var cleanMisspelling = misspelling.map { TextRuleMatcher.normalized($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if cleanMisspelling?.isEmpty == true { cleanMisspelling = nil }
        if let cleanMisspelling {
            guard cleanMisspelling.count <= Self.maxWordLength else { return .failure(.tooLong) }
            guard TextRuleMatcher.key(cleanMisspelling) != TextRuleMatcher.key(cleanWord) else {
                return .failure(.sameAsWord)
            }
            if let existing = entries.first(where: {
                $0.id != excluding && $0.misspelling.map(TextRuleMatcher.key) == TextRuleMatcher.key(cleanMisspelling)
            }) {
                return .failure(.aliasConflict(existing: existing.word))
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
            .sorted { $0.0.count == $1.0.count ? TextRuleMatcher.key($0.0) < TextRuleMatcher.key($1.0) : $0.0.count > $1.0.count }
    }

    /// Older installations could save one alias with several destinations. Keep all
    /// editable entries, but disable these ambiguous rules until the conflict is fixed.
    var conflictingAliases: [String] {
        Dictionary(grouping: entries.compactMap(\.misspelling), by: TextRuleMatcher.key)
            .filter { $0.value.count > 1 }.keys.sorted()
    }

    private func rebuildCompiledReplacementRules() {
        let conflicts = Set(conflictingAliases)
        compiledReplacementRules = entries.compactMap { entry -> CompiledReplacementRule? in
            guard let misspelling = entry.misspelling, !conflicts.contains(TextRuleMatcher.key(misspelling)) else { return nil }
            return CompiledReplacementRule(misspelling: misspelling, word: entry.word, allowProtectedText: entry.allowProtectedText)
        }.sorted {
            $0.misspelling.count == $1.misspelling.count
                ? TextRuleMatcher.key($0.misspelling) < TextRuleMatcher.key($1.misspelling)
                : $0.misspelling.count > $1.misspelling.count
        }
    }

    // MARK: - Persistence

    private var file: StoreFile<[DictionaryEntry]> { StoreFile(url: fileURL) }

    private func load() {
        recoveryAvailable = file.backup() != nil
        switch file.load() {
        case .success(let saved): entries = Array((saved ?? []).prefix(maxEntries))
        case .failure(let error):
            persistenceError = error
            loadBlocked = true
        }
    }

    @discardableResult
    func retrySave() -> Bool {
        // A transient read failure can be retried without discarding the original file.
        if loadBlocked {
            switch file.load(preserveCorrupt: false) {
            case .success(let saved):
                entries = Array((saved ?? []).prefix(maxEntries))
                loadBlocked = false
                persistenceError = nil
                rebuildCompiledReplacementRules()
                return true
            case .failure(let error): persistenceError = error; return false
            }
        }
        return commit(pendingEntries ?? entries)
    }

    @discardableResult
    func recoverFromBackup() -> Bool {
        guard let saved = file.backup() else { return false }
        do { try file.preserveForRecovery() }
        catch { persistenceError = .unreadable(error.localizedDescription); return false }
        loadBlocked = false
        recovered = true
        entries = Array(saved.prefix(maxEntries))
        pendingEntries = entries
        return commit(entries)
    }

    @discardableResult
    func startFresh() -> Bool {
        do { try file.preserveForRecovery() }
        catch { persistenceError = .unreadable(error.localizedDescription); return false }
        loadBlocked = false
        recovered = true
        return commit([])
    }

    private func commit(_ candidate: [DictionaryEntry]) -> Bool {
        guard !loadBlocked else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            try file.save(candidate, preservePrevious: !recovered)
            entries = candidate
            pendingEntries = nil
            persistenceError = nil
            recovered = false
            recoveryAvailable = file.backup() != nil
            rebuildCompiledReplacementRules()
            return true
        } catch {
            pendingEntries = candidate
            persistenceError = (error as? StorePersistenceError) ?? .writeFailed(error.localizedDescription)
            return false
        }
    }
}
