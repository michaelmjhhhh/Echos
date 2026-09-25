import Foundation

struct TranscriptEntry: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let date: Date
    let text: String

    var wordCount: Int { TextWordCounter.count(text) }
}

@MainActor
final class TranscriptStore: ObservableObject {
    @Published private(set) var entries: [TranscriptEntry] = []
    @Published private(set) var persistenceError: StorePersistenceError?
    @Published private(set) var isSaving = false
    @Published private(set) var recoveryAvailable = false

    private let fileURL: URL
    private let maxEntries: Int
    private let persistence: any HistoryPersisting
    private var persistenceRevision = 0
    private var persistenceTask: Task<Void, Never>?
    private var loadBlocked = false
    private var recovered = false
    private var deletionPending = false
    private var purgeRecoveryPending = false

    init(directory: URL? = nil, maxEntries: Int = 500, persistence: (any HistoryPersisting)? = nil) {
        self.maxEntries = max(0, maxEntries)
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Echo", isDirectory: true)
        let fileURL = base.appendingPathComponent("history.json")
        self.fileURL = fileURL
        self.persistence = persistence ?? HistoryPersistence(fileURL: fileURL)
        load()
    }

    func add(_ text: String) {
        entries.insert(TranscriptEntry(id: UUID(), date: Date(), text: text), at: 0)
        enforceRetentionBound()
        scheduleSave()
    }

    func clear() {
        entries = []
        deletionPending = true
        purgeRecoveryPending = true
        scheduleSave()
    }

    func delete(_ id: UUID) {
        guard entries.contains(where: { $0.id == id }) else { return }
        entries.removeAll { $0.id == id }
        deletionPending = true
        purgeRecoveryPending = true
        scheduleSave()
    }

    /// A false result means deletion has not been durably completed; the UI must
    /// keep the error/retry action visible even though the local list is empty.
    @discardableResult
    func clearPersisted() async -> Bool {
        clear()
        return await flushPersistence()
    }

    var todayEntries: [TranscriptEntry] { entries.filter { Calendar.current.isDateInToday($0.date) } }
    var todayWordCount: Int { todayEntries.reduce(0) { $0 + $1.wordCount } }

    /// Drains through the latest mutation, including any queued while a previous write ran.
    @discardableResult
    func flushPersistence() async -> Bool {
        var observed: Int
        repeat {
            observed = persistenceRevision
            await persistenceTask?.value
            await persistence.flush()
        } while observed != persistenceRevision
        return !loadBlocked && persistenceError == nil
    }

    func flushPersistenceForTesting() async { _ = await flushPersistence() }

    @discardableResult
    func retrySave() async -> Bool {
        if loadBlocked {
            switch file.load(preserveCorrupt: false) {
            case .success(let saved):
                // Preserve unsaved results from the current session ahead of older disk data.
                if !deletionPending {
                    let ids = Set(entries.map(\.id))
                    entries += (saved ?? []).filter { !ids.contains($0.id) }
                }
                enforceRetentionBound()
                loadBlocked = false
                persistenceError = nil
            case .failure(let error): persistenceError = error; return false
            }
        }
        scheduleSave()
        return await flushPersistence()
    }

    @discardableResult
    func recoverFromBackup() -> Bool {
        guard !isSaving, let saved = file.backup() else { return false }
        do { try file.preserveForRecovery() }
        catch { persistenceError = .unreadable(error.localizedDescription); return false }
        if !deletionPending {
            let currentIDs = Set(entries.map(\.id))
            entries += saved.filter { !currentIDs.contains($0.id) }
            enforceRetentionBound()
        }
        loadBlocked = false
        recovered = true
        scheduleSave()
        return true
    }

    @discardableResult
    func startFresh() async -> Bool {
        await persistenceTask?.value
        do { try file.preserveForRecovery() }
        catch { persistenceError = .unreadable(error.localizedDescription); return false }
        loadBlocked = false
        recovered = true
        entries = []
        deletionPending = true
        // Start fresh promises to keep the protected recovery copy. A later
        // explicit Clear History or per-entry deletion removes owned copies.
        purgeRecoveryPending = false
        scheduleSave()
        return await flushPersistence()
    }

    private var file: StoreFile<[TranscriptEntry]> { StoreFile(url: fileURL) }

    private func load() {
        recoveryAvailable = file.backup() != nil
        switch file.load() {
        case .success(let saved):
            entries = Array((saved ?? []).prefix(maxEntries))
            enforceRetentionBound()
        case .failure(let error): persistenceError = error; loadBlocked = true
        }
    }

    private func enforceRetentionBound() {
        if entries.count > maxEntries { entries.removeLast(entries.count - maxEntries) }
        var bytes = entries.reduce(0) { $0 + $1.text.utf8.count }
        while bytes > 16 * 1_024 * 1_024, entries.count > 1 {
            bytes -= entries.removeLast().text.utf8.count
        }
    }

    private func scheduleSave() {
        guard !loadBlocked else { return }
        persistenceRevision += 1
        let revision = persistenceRevision
        let snapshot = entries
        let preservePrevious = !recovered
        let clearBackup = deletionPending || snapshot.isEmpty
        let purgeRecovery = purgeRecoveryPending
        let previous = persistenceTask
        let persistence = persistence
        isSaving = true
        persistenceTask = Task { [weak self] in
            await previous?.value
            await persistence.submit(entries: snapshot, revision: revision, preservePrevious: preservePrevious, clearBackup: clearBackup, purgeRecovery: purgeRecovery)
            let error = await persistence.lastError()
            guard let self else { return }
            if self.persistenceRevision == revision {
                self.persistenceError = error
                self.isSaving = false
                if error == nil {
                    self.recovered = false
                    self.deletionPending = false
                    self.purgeRecoveryPending = false
                    self.recoveryAvailable = !clearBackup && FileManager.default.fileExists(atPath: self.file.backupURL.path)
                }
            }
        }
    }
}
