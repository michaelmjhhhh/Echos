import Foundation

/// One snippet: a spoken trigger phrase and the text it expands into.
struct Snippet: Identifiable, Codable, Equatable {
    let id: UUID
    /// The phrase to say (≤60 chars), matched case-insensitively as whole words.
    var trigger: String
    /// Inserted in place of the trigger, verbatim (≤4000 chars).
    var expansion: String
    let dateAdded: Date
    var standaloneOnly: Bool
    var allowProtectedText: Bool

    init(id: UUID, trigger: String, expansion: String, dateAdded: Date, standaloneOnly: Bool = false, allowProtectedText: Bool = false) {
        self.id = id
        self.trigger = trigger
        self.expansion = expansion
        self.dateAdded = dateAdded
        self.standaloneOnly = standaloneOnly
        self.allowProtectedText = allowProtectedText
    }

    private enum CodingKeys: String, CodingKey { case id, trigger, expansion, dateAdded, standaloneOnly, allowProtectedText }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        trigger = try values.decode(String.self, forKey: .trigger)
        expansion = try values.decode(String.self, forKey: .expansion)
        dateAdded = try values.decode(Date.self, forKey: .dateAdded)
        standaloneOnly = try values.decodeIfPresent(Bool.self, forKey: .standaloneOnly) ?? false
        allowProtectedText = try values.decodeIfPresent(Bool.self, forKey: .allowProtectedText) ?? false
    }
}

enum SnippetError: LocalizedError, Equatable {
    case emptyTrigger
    case emptyExpansion
    case triggerTooLong
    case expansionTooLong
    case duplicate(existing: String)
    case full
    case persistence(String)

    var errorDescription: String? {
        switch self {
        case .emptyTrigger: return "Enter a trigger phrase first."
        case .emptyExpansion: return "Enter the text to insert."
        case .triggerTooLong: return "Triggers can be at most \(SnippetStore.maxTriggerLength) characters."
        case .expansionTooLong: return "Snippets can be at most \(SnippetStore.maxExpansionLength) characters."
        case .duplicate(let existing): return "Already used by the snippet “\(existing)”."
        case .persistence(let message): return message
        case .full: return "Snippets are full (\(SnippetStore.defaultMaxEntries)). Remove some to add more."
        }
    }
}

/// The user's saved snippets, persisted as JSON in Application Support next to
/// the dictionary. Feeds `SnippetProcessor` via `rules`. Everything stays on
/// this Mac.
@MainActor
final class SnippetStore: ObservableObject {
    nonisolated static let maxTriggerLength = 60
    nonisolated static let maxExpansionLength = 4000
    nonisolated static let defaultMaxEntries = 1000

    @Published private(set) var entries: [Snippet] = []
    @Published private(set) var persistenceError: StorePersistenceError?
    @Published private(set) var isSaving = false
    @Published private(set) var recoveryAvailable = false
    private var loadBlocked = false
    private var recovered = false
    private var pendingEntries: [Snippet]?
    private(set) var compiledRules: [CompiledSnippetRule] = []

    private let fileURL: URL
    private let maxEntries: Int

    init(directory: URL? = nil, maxEntries: Int = SnippetStore.defaultMaxEntries) {
        self.maxEntries = max(0, maxEntries)
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Echo", isDirectory: true)
        fileURL = base.appendingPathComponent("snippets.json")
        load()
        rebuildCompiledRules()
    }

    // MARK: - Mutations

    @discardableResult
    func add(trigger: String, expansion: String, standaloneOnly: Bool = false, allowProtectedText: Bool = false) -> Result<Snippet, SnippetError> {
        switch validate(trigger: trigger, expansion: expansion, excluding: nil) {
        case .failure(let error): return .failure(error)
        case .success(let clean):
            guard entries.count < maxEntries else { return .failure(.full) }
            let snippet = Snippet(
                id: UUID(),
                trigger: clean.trigger,
                expansion: clean.expansion,
                dateAdded: Date(),
                standaloneOnly: standaloneOnly,
                allowProtectedText: allowProtectedText
            )
            var candidate = entries
            candidate.insert(snippet, at: 0)
            guard commit(candidate) else { return .failure(.persistence(persistenceError!.localizedDescription)) }
            return .success(snippet)
        }
    }

    @discardableResult
    func update(_ snippet: Snippet) -> Result<Snippet, SnippetError> {
        guard let index = entries.firstIndex(where: { $0.id == snippet.id }) else {
            // Editing a snippet that was deleted underneath the sheet — treat as add.
            return add(trigger: snippet.trigger, expansion: snippet.expansion, standaloneOnly: snippet.standaloneOnly, allowProtectedText: snippet.allowProtectedText)
        }
        switch validate(trigger: snippet.trigger, expansion: snippet.expansion, excluding: snippet.id) {
        case .failure(let error): return .failure(error)
        case .success(let clean):
            var updated = entries[index]
            updated.trigger = clean.trigger
            updated.expansion = clean.expansion
            updated.standaloneOnly = snippet.standaloneOnly
            updated.allowProtectedText = snippet.allowProtectedText
            var candidate = entries
            candidate[index] = updated
            guard commit(candidate) else { return .failure(.persistence(persistenceError!.localizedDescription)) }
            return .success(updated)
        }
    }

    @discardableResult
    func delete(_ id: UUID) -> Bool { commit(entries.filter { $0.id != id }) }

    /// Validates and normalizes a prospective trigger/expansion pair.
    /// Pass `excluding` when editing so the snippet doesn't collide with itself.
    func validate(trigger: String, expansion: String, excluding: UUID?) -> Result<(trigger: String, expansion: String), SnippetError> {
        let cleanTrigger = TextRuleMatcher.normalized(trigger.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !cleanTrigger.isEmpty else { return .failure(.emptyTrigger) }
        guard cleanTrigger.count <= Self.maxTriggerLength else { return .failure(.triggerTooLong) }
        guard !expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failure(.emptyExpansion) }
        guard expansion.count <= Self.maxExpansionLength else { return .failure(.expansionTooLong) }
        if let existing = entries.first(where: {
            $0.id != excluding && TextRuleMatcher.key($0.trigger) == TextRuleMatcher.key(cleanTrigger)
        }) {
            return .failure(.duplicate(existing: existing.trigger))
        }
        return .success((cleanTrigger, expansion))
    }

    // MARK: - Derived views

    /// Matching rules, longest trigger first so overlapping triggers can't
    /// clobber each other ("my email signature" before "my email").
    var rules: [(trigger: String, expansion: String)] {
        entries
            .map { (trigger: $0.trigger, expansion: $0.expansion) }
            .sorted { $0.trigger.count == $1.trigger.count ? TextRuleMatcher.key($0.trigger) < TextRuleMatcher.key($1.trigger) : $0.trigger.count > $1.trigger.count }
    }

    private func rebuildCompiledRules() {
        compiledRules = entries.sorted {
            $0.trigger.count == $1.trigger.count ? TextRuleMatcher.key($0.trigger) < TextRuleMatcher.key($1.trigger) : $0.trigger.count > $1.trigger.count
        }.compactMap {
            CompiledSnippetRule(trigger: $0.trigger, expansion: $0.expansion, standaloneOnly: $0.standaloneOnly, allowProtectedText: $0.allowProtectedText)
        }
    }

    // MARK: - Persistence

    private var file: StoreFile<[Snippet]> { StoreFile(url: fileURL) }

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
        if loadBlocked {
            switch file.load(preserveCorrupt: false) {
            case .success(let saved):
                entries = Array((saved ?? []).prefix(maxEntries))
                loadBlocked = false
                persistenceError = nil
                rebuildCompiledRules()
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

    private func commit(_ candidate: [Snippet]) -> Bool {
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
            rebuildCompiledRules()
            return true
        } catch {
            pendingEntries = candidate
            persistenceError = (error as? StorePersistenceError) ?? .writeFailed(error.localizedDescription)
            return false
        }
    }
}
