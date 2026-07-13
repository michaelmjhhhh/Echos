import Foundation

/// One snippet: a spoken trigger phrase and the text it expands into.
struct Snippet: Identifiable, Codable, Equatable {
    let id: UUID
    /// The phrase to say (≤60 chars), matched case-insensitively as whole words.
    var trigger: String
    /// Inserted in place of the trigger, verbatim (≤4000 chars).
    var expansion: String
    let dateAdded: Date
}

enum SnippetError: LocalizedError, Equatable {
    case emptyTrigger
    case emptyExpansion
    case triggerTooLong
    case expansionTooLong
    case duplicate(existing: String)
    case full

    var errorDescription: String? {
        switch self {
        case .emptyTrigger: return "Enter a trigger phrase first."
        case .emptyExpansion: return "Enter the text to insert."
        case .triggerTooLong: return "Triggers can be at most \(SnippetStore.maxTriggerLength) characters."
        case .expansionTooLong: return "Snippets can be at most \(SnippetStore.maxExpansionLength) characters."
        case .duplicate(let existing): return "Already used by the snippet “\(existing)”."
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
    private(set) var compiledRules: [CompiledSnippetRule] = []

    private let fileURL: URL
    private let maxEntries: Int

    init(directory: URL? = nil, maxEntries: Int = SnippetStore.defaultMaxEntries) {
        self.maxEntries = maxEntries
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Echo", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("snippets.json")
        load()
        rebuildCompiledRules()
    }

    // MARK: - Mutations

    @discardableResult
    func add(trigger: String, expansion: String) -> Result<Snippet, SnippetError> {
        switch validate(trigger: trigger, expansion: expansion, excluding: nil) {
        case .failure(let error): return .failure(error)
        case .success(let clean):
            guard entries.count < maxEntries else { return .failure(.full) }
            let snippet = Snippet(
                id: UUID(),
                trigger: clean.trigger,
                expansion: clean.expansion,
                dateAdded: Date()
            )
            entries.insert(snippet, at: 0)
            rebuildCompiledRules()
            save()
            return .success(snippet)
        }
    }

    @discardableResult
    func update(_ snippet: Snippet) -> Result<Snippet, SnippetError> {
        guard let index = entries.firstIndex(where: { $0.id == snippet.id }) else {
            // Editing a snippet that was deleted underneath the sheet — treat as add.
            return add(trigger: snippet.trigger, expansion: snippet.expansion)
        }
        switch validate(trigger: snippet.trigger, expansion: snippet.expansion, excluding: snippet.id) {
        case .failure(let error): return .failure(error)
        case .success(let clean):
            var updated = entries[index]
            updated.trigger = clean.trigger
            updated.expansion = clean.expansion
            entries[index] = updated
            rebuildCompiledRules()
            save()
            return .success(updated)
        }
    }

    func delete(_ id: UUID) {
        entries.removeAll { $0.id == id }
        rebuildCompiledRules()
        save()
    }

    /// Validates and normalizes a prospective trigger/expansion pair.
    /// Pass `excluding` when editing so the snippet doesn't collide with itself.
    func validate(trigger: String, expansion: String, excluding: UUID?) -> Result<(trigger: String, expansion: String), SnippetError> {
        let cleanTrigger = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTrigger.isEmpty else { return .failure(.emptyTrigger) }
        guard cleanTrigger.count <= Self.maxTriggerLength else { return .failure(.triggerTooLong) }
        let cleanExpansion = expansion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanExpansion.isEmpty else { return .failure(.emptyExpansion) }
        guard cleanExpansion.count <= Self.maxExpansionLength else { return .failure(.expansionTooLong) }
        if let existing = entries.first(where: {
            $0.id != excluding && $0.trigger.caseInsensitiveCompare(cleanTrigger) == .orderedSame
        }) {
            return .failure(.duplicate(existing: existing.trigger))
        }
        return .success((cleanTrigger, cleanExpansion))
    }

    // MARK: - Derived views

    /// Matching rules, longest trigger first so overlapping triggers can't
    /// clobber each other ("my email signature" before "my email").
    var rules: [(trigger: String, expansion: String)] {
        entries
            .map { (trigger: $0.trigger, expansion: $0.expansion) }
            .sorted { $0.trigger.count > $1.trigger.count }
    }

    private func rebuildCompiledRules() {
        compiledRules = rules.compactMap {
            CompiledSnippetRule(trigger: $0.trigger, expansion: $0.expansion)
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? decoder.decode([Snippet].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
