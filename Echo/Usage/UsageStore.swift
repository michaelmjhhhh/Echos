import AppKit
import Combine
import SQLite3

struct UsageTotals: Equatable, Sendable, Codable {
    var words = 0
    var dictations = 0
    var wordsThisMonth = 0
    var activeDays = 0
    var expandedWords = 0
}

struct AppUsage: Identifiable, Equatable, Sendable {
    let bundleID: String
    let name: String
    let words: Int
    var id: String { bundleID }
}

enum DictationOutcome: String, Sendable, Equatable, Codable {
    // Legacy values remain readable; success means recognized, never verified delivery.
    case success, noAudio, emptyTranscript, transcriptionFailure
    case recognized, pasteDispatched, copied, awaitingCopy, cancelled, noSpeech, failed, verifiedDelivery

    var hasTranscript: Bool {
        switch self {
        case .success, .recognized, .pasteDispatched, .copied, .awaitingCopy, .verifiedDelivery: true
        default: false
        }
    }
}

struct DictationOperationalMetrics: Sendable, Equatable, Codable {
    let rawAudioDuration: TimeInterval
    let selectedAudioDuration: TimeInterval
    let finalizationDuration: TimeInterval
    let trimmingDuration: TimeInterval
    let transcriptionDuration: TimeInterval?
    let processingDuration: TimeInterval?
    let insertionDuration: TimeInterval?
    let historyPersistenceDuration: TimeInterval?
    let totalLatency: TimeInterval
    let trimmingApplied: Bool
    let droppedBufferCount: Int
    let finalizationTimedOut: Bool
    let modelVariant: String
    var outcome: DictationOutcome
    // Monotonic elapsed seconds supplied by the session owner. No user content.
    var transportReadyDuration: TimeInterval? = nil
    var captureTailDuration: TimeInterval? = nil
    var inputGapCount: Int? = nil
    var captureInterrupted: Bool? = nil
    var startupDuration: TimeInterval? = nil
    var modelLoadingDuration: TimeInterval? = nil
    var promptConstructionDuration: TimeInterval? = nil
    var featureExtractionDuration: TimeInterval? = nil
    var encoderDuration: TimeInterval? = nil
    var decoderDuration: TimeInterval? = nil
    var decodingAttempts: Int? = nil
    var trimReason: String? = nil
    var language: String? = nil
    var vocabularyTokenBudget: Int? = nil
    var decodingFallbackCount: Int? = nil
    var appVersion: String? = nil
    var buildVersion: String? = nil
    var dependencyVersion: String? = nil
}

struct UsageSnapshot: Sendable {
    var totals = UsageTotals()
    var todayWords = 0
    var todayDictations = 0
    var wpm = 0
    var apps: [AppUsage] = []
    var daily: [Date: Int] = [:]
    var currentStreak = 0
    var longestStreak = 0
    var outcomes: [String: Int] = [:]
}

/// Counts, timings and app identifiers only. SQLite work is ordered off the
/// main actor; SwiftUI reads snapshot without performing filesystem work.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var revision = 0
    @Published private(set) var snapshot = UsageSnapshot()
    @Published private(set) var persistenceError: String?
    @Published private(set) var isSaving = false
    private let database: UsageDatabase
    private var enabled = true
    private var retentionDays = 0
    private var pendingWrites = 0
    private var failedWrites: [(id: Int, operation: @Sendable (UsageDatabase) throws -> Void)] = []
    private var publicationID = 0
    private var appliedPublicationID = 0
    private var minimumRetryPublicationID = 0
    private var refreshObservers = Set<AnyCancellable>()

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Echo", isDirectory: true)
        database = UsageDatabase(directory: base)
        // Do not retain an unused store through a pending read/connection close.
        // This also lets startup finish before assembling its first UI snapshot.
        Task { @MainActor [weak self] in self?.refresh() }
        for name in [Notification.Name.NSCalendarDayChanged, NSApplication.didBecomeActiveNotification, NSNotification.Name.NSSystemTimeZoneDidChange] {
            NotificationCenter.default.publisher(for: name).receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refresh(); self?.prune() }.store(in: &refreshObservers)
        }
    }

    func configure(enabled: Bool, retentionDays: Int) {
        let changedRetention = self.retentionDays != retentionDays
        self.enabled = enabled
        self.retentionDays = max(0, retentionDays)
        if changedRetention { prune() }
    }

    func record(words: Int, duration: TimeInterval, latency: TimeInterval?, appBundleID: String?, appName: String?,
                date: Date = Date(), metrics: DictationOperationalMetrics? = nil, expandedWords: Int? = nil,
                sessionID: UUID? = nil) {
        guard enabled else { return }
        let row = UsageRecord(date: date, words: max(0, words), expandedWords: max(0, expandedWords ?? words),
                              duration: duration, latency: latency, appBundleID: appBundleID, appName: appName,
                              metrics: metrics, sessionID: sessionID)
        enqueue { database in try database.record(row) }
        prune()
    }

    func updateOutcome(sessionID: UUID, outcome: DictationOutcome) {
        guard enabled else { return }
        enqueue { database in try database.updateOutcome(sessionID: sessionID, outcome: outcome) }
    }

    func refresh() {
        publicationID += 1
        let requestID = publicationID
        let database = database
        UsageDatabase.queue.async { [weak self] in
            do {
                let snapshot = try database.makeSnapshot()
                Task { @MainActor [weak self] in
                    guard let self, requestID >= appliedPublicationID else { return }
                    appliedPublicationID = requestID
                    self.snapshot = snapshot
                }
            } catch {
                let message = error.localizedDescription
                Task { @MainActor [weak self] in self?.persistenceError = message }
            }
        }
    }

    func clear() async -> Bool {
        let clearPublicationID = publicationID + 1
        let saved = await mutateAndWait { database in try database.clear() }
        if saved {
            minimumRetryPublicationID = clearPublicationID
            failedWrites.removeAll { $0.id <= clearPublicationID }
        }
        return saved
    }

    func retrySave() {
        let operations = failedWrites.sorted { $0.id < $1.id }
        failedWrites.removeAll()
        enqueue { database in try database.reopenIfNeeded() }
        for failure in operations { enqueue(failure.operation, retrying: failure.id) }
    }

    func flushPersistence() async -> Bool {
        let database = database
        return await withCheckedContinuation { continuation in
            UsageDatabase.queue.async {
                do { try database.checkpoint(); continuation.resume(returning: !database.hasUnsavedWrites) }
                catch { continuation.resume(returning: false) }
            }
        }
    }

    func exportAggregates(to url: URL) async -> Bool {
        let database = database
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                UsageDatabase.queue.async {
                    do {
                        let data = try database.aggregateExport()
                        try data.write(to: url, options: .atomic)
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
            return true
        } catch { persistenceError = error.localizedDescription; return false }
    }

    // Compatibility APIs for existing callers. Views must use snapshot.
    func totals(now: Date = Date(), calendar: Calendar = .current) -> UsageTotals {
        UsageDatabase.queue.sync { UsageDatabase.snapshot((try? database.records()) ?? [], now: now, calendar: calendar).totals }
    }
    func averageWPM(days: Int = 30, now: Date = Date()) -> Int {
        UsageDatabase.queue.sync { UsageDatabase.wordsPerMinute((try? database.records()) ?? [], days: days, now: now) }
    }
    func perAppWords(limit: Int = 6) -> [AppUsage] {
        UsageDatabase.queue.sync { Array(UsageDatabase.snapshot((try? database.records()) ?? []).apps.prefix(max(0, limit))) }
    }
    func dailyWords(since: Date, calendar: Calendar = .current) -> [Date: Int] {
        UsageDatabase.queue.sync {
            UsageDatabase.snapshot(((try? database.records()) ?? []).filter { $0.date >= since }, calendar: calendar).daily
        }
    }
    #if DEBUG
    func latestOperationalMetricsForTesting() -> DictationOperationalMetrics? {
        UsageDatabase.queue.sync { (try? database.records())?.last?.metrics }
    }
    #endif

    private func prune() {
        let days = retentionDays
        guard days > 0 else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        enqueue { database in try database.prune(before: cutoff) }
    }
    private func enqueue(_ operation: @escaping @Sendable (UsageDatabase) throws -> Void, retrying failedID: Int? = nil) {
        pendingWrites += 1
        isSaving = true
        publicationID += 1
        let requestID = publicationID
        let database = database
        let failureID = failedID ?? requestID
        UsageDatabase.queue.async { [weak self] in
            let result: Result<UsageSnapshot, Error>
            var operationCompleted = false
            do {
                try operation(database)
                operationCompleted = true
                database.resolveFailedWrite(failureID)
                result = .success(try database.makeSnapshot())
            } catch {
                if !operationCompleted { database.markFailedWrite(failureID) }
                result = .failure(error)
            }
            let mayRetryOperation = !operationCompleted
            Task { @MainActor [weak self] in
                guard let self else { return }
                pendingWrites -= 1
                isSaving = pendingWrites > 0
                switch result {
                case .success(let updated):
                    if requestID >= appliedPublicationID { snapshot = updated; appliedPublicationID = requestID }
                    if failedWrites.isEmpty { persistenceError = nil }
                    revision += 1
                case .failure(let error):
                    guard requestID > minimumRetryPublicationID else { return }
                    persistenceError = error.localizedDescription
                    if mayRetryOperation { failedWrites.append((failureID, operation)) }
                }
            }
        }
    }
    private func mutateAndWait(_ operation: @escaping @Sendable (UsageDatabase) throws -> Void) async -> Bool {
        publicationID += 1
        let requestID = publicationID
        let database = database
        isSaving = true
        let result: Result<UsageSnapshot, Error> = await withCheckedContinuation { continuation in
            UsageDatabase.queue.async {
                do {
                    try operation(database)
                    database.resolveFailedWrite(requestID)
                    continuation.resume(returning: .success(try database.makeSnapshot()))
                } catch {
                    database.markFailedWrite(requestID)
                    continuation.resume(returning: .failure(error))
                }
            }
        }
        isSaving = pendingWrites > 0
        switch result {
        case .success(let updated):
            if requestID >= appliedPublicationID { snapshot = updated; appliedPublicationID = requestID }
            persistenceError = nil; revision += 1; return true
        case .failure(let error):
            persistenceError = error.localizedDescription
            failedWrites.append((requestID, operation))
            return false
        }
    }
}

private struct UsageRecord: Sendable {
    let date: Date
    let words: Int
    let expandedWords: Int
    let duration: TimeInterval
    let latency: TimeInterval?
    let appBundleID: String?
    let appName: String?
    var metrics: DictationOperationalMetrics?
    let sessionID: UUID?
    var recognized: Bool { metrics?.outcome.hasTranscript ?? true }
}

/// A single serial queue also preserves ordering when stores reopen the same file.
private final class UsageDatabase: @unchecked Sendable {
    static let queue = DispatchQueue(label: "echo.usage.persistence", qos: .utility)
    private var db: OpaquePointer?
    private let directory: URL
    private var openError: Error?
    private var failedWriteIDs = Set<Int>()
    var hasUnsavedWrites: Bool { !failedWriteIDs.isEmpty }
    func markFailedWrite(_ id: Int) { failedWriteIDs.insert(id) }
    func resolveFailedWrite(_ id: Int) { failedWriteIDs.remove(id) }
    private struct DatabaseError: LocalizedError { let message: String; var errorDescription: String? { message } }

    init(directory: URL) {
        self.directory = directory
        Self.queue.sync {
            do { try open() } catch { openError = error }
        }
    }
    func reopenIfNeeded() throws {
        guard openError != nil else { return }
        sqlite3_close(db)
        db = nil
        openError = nil
        do { try open() } catch { openError = error; throw error }
    }
    private func open() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard sqlite3_open(directory.appendingPathComponent("usage.sqlite").path, &db) == SQLITE_OK else { throw failure() }
        sqlite3_busy_timeout(db, 3_000)
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA secure_delete=ON;")
        try exec("""
            CREATE TABLE IF NOT EXISTS dictations (
              id INTEGER PRIMARY KEY AUTOINCREMENT, created_at REAL NOT NULL,
              word_count INTEGER NOT NULL, duration_seconds REAL NOT NULL, latency_seconds REAL,
              app_bundle_id TEXT, app_name TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_dictations_created ON dictations(created_at);
            CREATE TABLE IF NOT EXISTS usage_diagnostics (
              dictation_id INTEGER PRIMARY KEY, session_id TEXT UNIQUE,
              expanded_word_count INTEGER NOT NULL, metrics_json TEXT
            );
            """)
        try migrate()
    }
    deinit { sqlite3_close(db) }
    private func failure() -> Error {
        DatabaseError(message: "Usage statistics could not be saved: \(db.map { String(cString: sqlite3_errmsg($0)) } ?? "database unavailable")")
    }
    private func exec(_ sql: String) throws {
        if let openError { throw openError }
        guard db != nil, sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func statement(_ sql: String) throws -> OpaquePointer {
        if let openError { throw openError }
        var statement: OpaquePointer?
        guard db != nil, sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        return statement
    }
    private func step(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }
    private func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        sqlite3_column_text(statement, index).map { String(cString: $0) }
    }
    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: String?) {
        if let value { sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        else { sqlite3_bind_null(statement, index) }
    }
    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: Double?) {
        if let value { sqlite3_bind_double(statement, index, value) } else { sqlite3_bind_null(statement, index) }
    }
    private func migrate() throws {
        let columns = try statement("PRAGMA table_info(dictations)")
        var names = Set<String>()
        while sqlite3_step(columns) == SQLITE_ROW { if let name = text(columns, 1) { names.insert(name) } }
        sqlite3_finalize(columns)
        let definitions = ["raw_audio_seconds REAL", "selected_audio_seconds REAL", "finalization_seconds REAL", "trimming_seconds REAL",
                           "transcription_seconds REAL", "processing_seconds REAL", "insertion_seconds REAL", "history_persistence_seconds REAL",
                           "total_latency_seconds REAL", "trimming_applied INTEGER", "conversion_drop_count INTEGER", "finalization_timed_out INTEGER",
                           "model_variant TEXT", "outcome TEXT"]
        for definition in definitions where !names.contains(String(definition.split(separator: " ")[0])) {
            try exec("ALTER TABLE dictations ADD COLUMN \(definition)")
        }
    }
    func record(_ row: UsageRecord) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            let insert = try statement("""
                INSERT INTO dictations (created_at, word_count, duration_seconds, latency_seconds, app_bundle_id, app_name,
                  raw_audio_seconds, selected_audio_seconds, finalization_seconds, trimming_seconds, transcription_seconds,
                  processing_seconds, insertion_seconds, history_persistence_seconds, total_latency_seconds, trimming_applied,
                  conversion_drop_count, finalization_timed_out, model_variant, outcome)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
            defer { sqlite3_finalize(insert) }
            let m = row.metrics
            bind(insert, 1, row.date.timeIntervalSince1970); sqlite3_bind_int64(insert, 2, Int64(row.words))
            bind(insert, 3, row.duration); bind(insert, 4, row.latency)
            bind(insert, 5, row.appBundleID); bind(insert, 6, row.appName)
            let values: [Double?] = [m?.rawAudioDuration, m?.selectedAudioDuration, m?.finalizationDuration,
                                    m?.trimmingDuration, m?.transcriptionDuration, m?.processingDuration,
                                    m?.insertionDuration, m?.historyPersistenceDuration, m?.totalLatency]
            for (index, value) in values.enumerated() { bind(insert, Int32(index + 7), value) }
            if let m {
                sqlite3_bind_int(insert, 16, m.trimmingApplied ? 1 : 0)
                sqlite3_bind_int64(insert, 17, Int64(m.droppedBufferCount))
                sqlite3_bind_int(insert, 18, m.finalizationTimedOut ? 1 : 0)
            }
            bind(insert, 19, m?.modelVariant); bind(insert, 20, m?.outcome.rawValue)
            try step(insert)
            let id = sqlite3_last_insert_rowid(db)
            let diagnostic = try statement("INSERT INTO usage_diagnostics (dictation_id, session_id, expanded_word_count, metrics_json) VALUES (?, ?, ?, ?)")
            defer { sqlite3_finalize(diagnostic) }
            sqlite3_bind_int64(diagnostic, 1, id); bind(diagnostic, 2, row.sessionID?.uuidString)
            sqlite3_bind_int64(diagnostic, 3, Int64(row.expandedWords))
            let json = try m.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
            bind(diagnostic, 4, json); try step(diagnostic)
            try exec("COMMIT")
        } catch { try? exec("ROLLBACK"); throw error }
    }
    func updateOutcome(sessionID: UUID, outcome: DictationOutcome) throws {
        let select = try statement("SELECT dictation_id, metrics_json FROM usage_diagnostics WHERE session_id = ?")
        defer { sqlite3_finalize(select) }
        bind(select, 1, sessionID.uuidString)
        guard sqlite3_step(select) == SQLITE_ROW else { return }
        let id = sqlite3_column_int64(select, 0)
        var metrics = text(select, 1).flatMap { try? JSONDecoder().decode(DictationOperationalMetrics.self, from: Data($0.utf8)) }
        metrics?.outcome = outcome
        try exec("BEGIN IMMEDIATE")
        do {
            let update = try statement("UPDATE dictations SET outcome = ? WHERE id = ?")
            defer { sqlite3_finalize(update) }
            bind(update, 1, outcome.rawValue); sqlite3_bind_int64(update, 2, id); try step(update)
            let details = try statement("UPDATE usage_diagnostics SET metrics_json = ? WHERE dictation_id = ?")
            defer { sqlite3_finalize(details) }
            bind(details, 1, try metrics.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) })
            sqlite3_bind_int64(details, 2, id); try step(details)
            try exec("COMMIT")
        } catch { try? exec("ROLLBACK"); throw error }
    }
    func records() throws -> [UsageRecord] {
        let query = try statement("""
            SELECT d.created_at, d.word_count, d.duration_seconds, d.latency_seconds, d.app_bundle_id, d.app_name,
                   x.expanded_word_count, x.metrics_json, x.session_id,
                   d.raw_audio_seconds, d.selected_audio_seconds, d.finalization_seconds, d.trimming_seconds,
                   d.transcription_seconds, d.processing_seconds, d.insertion_seconds, d.history_persistence_seconds,
                   d.total_latency_seconds, d.trimming_applied, d.conversion_drop_count, d.finalization_timed_out,
                   d.model_variant, d.outcome
            FROM dictations d LEFT JOIN usage_diagnostics x ON x.dictation_id = d.id ORDER BY d.id
            """)
        defer { sqlite3_finalize(query) }
        var rows: [UsageRecord] = []
        func number(_ index: Int32) -> Double? { sqlite3_column_type(query, index) == SQLITE_NULL ? nil : sqlite3_column_double(query, index) }
        while sqlite3_step(query) == SQLITE_ROW {
            var metrics = text(query, 7).flatMap { try? JSONDecoder().decode(DictationOperationalMetrics.self, from: Data($0.utf8)) }
            if metrics == nil, let model = text(query, 21), let outcome = text(query, 22).flatMap(DictationOutcome.init(rawValue:)) {
                metrics = DictationOperationalMetrics(rawAudioDuration: number(9) ?? 0, selectedAudioDuration: number(10) ?? 0,
                    finalizationDuration: number(11) ?? 0, trimmingDuration: number(12) ?? 0,
                    transcriptionDuration: number(13), processingDuration: number(14), insertionDuration: number(15),
                    historyPersistenceDuration: number(16), totalLatency: number(17) ?? 0, trimmingApplied: sqlite3_column_int(query, 18) != 0,
                    droppedBufferCount: Int(sqlite3_column_int64(query, 19)), finalizationTimedOut: sqlite3_column_int(query, 20) != 0,
                    modelVariant: model, outcome: outcome)
            }
            rows.append(UsageRecord(date: Date(timeIntervalSince1970: sqlite3_column_double(query, 0)),
                words: Int(sqlite3_column_int64(query, 1)), expandedWords: Int(number(6) ?? sqlite3_column_double(query, 1)),
                duration: sqlite3_column_double(query, 2), latency: number(3), appBundleID: text(query, 4), appName: text(query, 5),
                metrics: metrics, sessionID: text(query, 8).flatMap(UUID.init(uuidString:))))
        }
        return rows
    }
    func clear() throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try exec("DELETE FROM usage_diagnostics; DELETE FROM dictations; COMMIT;")
            try exec("PRAGMA wal_checkpoint(TRUNCATE)")
            failedWriteIDs.removeAll()
        } catch { try? exec("ROLLBACK"); throw error }
    }
    func prune(before cutoff: Date) throws {
        let query = try statement("DELETE FROM dictations WHERE created_at < ?")
        defer { sqlite3_finalize(query) }
        bind(query, 1, cutoff.timeIntervalSince1970); try step(query)
        try exec("DELETE FROM usage_diagnostics WHERE dictation_id NOT IN (SELECT id FROM dictations)")
    }
    func checkpoint() throws { try exec("PRAGMA wal_checkpoint(FULL)") }
    static func wordsPerMinute(_ rows: [UsageRecord], days: Int = 30, now: Date = Date()) -> Int {
        let eligible = rows.filter { $0.recognized && $0.date >= now.addingTimeInterval(-Double(days) * 86_400) && $0.duration > 0 }
        let seconds = eligible.reduce(0) { $0 + $1.duration }
        return seconds > 0 ? Int((Double(eligible.reduce(0) { $0 + $1.words }) / seconds * 60).rounded()) : 0
    }
    static func snapshot(_ rows: [UsageRecord], now: Date = Date(), calendar: Calendar = .current) -> UsageSnapshot {
        var result = UsageSnapshot()
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
        var apps: [String: AppUsage] = [:]
        for row in rows {
            result.outcomes[row.metrics?.outcome.rawValue ?? "legacyRecognized", default: 0] += 1
            guard row.recognized else { continue }
            result.totals.words += row.words; result.totals.expandedWords += row.expandedWords; result.totals.dictations += 1
            if row.date >= monthStart { result.totals.wordsThisMonth += row.words }
            if calendar.isDate(row.date, inSameDayAs: now) { result.todayWords += row.words; result.todayDictations += 1 }
            result.daily[calendar.startOfDay(for: row.date), default: 0] += row.words
            let id = row.appBundleID ?? "unknown"
            apps[id] = AppUsage(bundleID: id, name: row.appName ?? apps[id]?.name ?? "Unknown", words: (apps[id]?.words ?? 0) + row.words)
        }
        result.totals.activeDays = result.daily.count
        result.wpm = wordsPerMinute(rows, now: now)
        result.apps = apps.values.sorted { $0.words == $1.words ? $0.bundleID < $1.bundleID : $0.words > $1.words }
        let streak = Streaks.compute(activeDays: Set(result.daily.keys), today: now, calendar: calendar)
        result.currentStreak = streak.current; result.longestStreak = streak.longest
        return result
    }
    /// Statistics queries operate on numeric columns, without decoding every
    /// stored diagnostic payload after each dictation.
    func makeSnapshot() throws -> UsageSnapshot {
        var result = UsageSnapshot()
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now).timeIntervalSince1970
        let tomorrow = (calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now).timeIntervalSince1970
        let month = (calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now).timeIntervalSince1970
        let recognized = "(d.outcome IS NULL OR d.outcome IN ('success','recognized','pasteDispatched','copied','awaitingCopy','verifiedDelivery'))"
        let totals = try statement("""
            SELECT COALESCE(SUM(d.word_count), 0), COUNT(*), COALESCE(SUM(COALESCE(x.expanded_word_count, d.word_count)), 0),
                   COALESCE(SUM(CASE WHEN d.created_at >= ? THEN d.word_count ELSE 0 END), 0),
                   COALESCE(SUM(CASE WHEN d.created_at >= ? AND d.created_at < ? THEN d.word_count ELSE 0 END), 0),
                   COALESCE(SUM(CASE WHEN d.created_at >= ? AND d.created_at < ? THEN 1 ELSE 0 END), 0)
            FROM dictations d LEFT JOIN usage_diagnostics x ON x.dictation_id = d.id WHERE \(recognized)
            """)
        defer { sqlite3_finalize(totals) }
        bind(totals, 1, month); bind(totals, 2, today); bind(totals, 3, tomorrow)
        bind(totals, 4, today); bind(totals, 5, tomorrow)
        guard sqlite3_step(totals) == SQLITE_ROW else { throw failure() }
        result.totals.words = Int(sqlite3_column_int64(totals, 0))
        result.totals.dictations = Int(sqlite3_column_int64(totals, 1))
        result.totals.expandedWords = Int(sqlite3_column_int64(totals, 2))
        result.totals.wordsThisMonth = Int(sqlite3_column_int64(totals, 3))
        result.todayWords = Int(sqlite3_column_int64(totals, 4))
        result.todayDictations = Int(sqlite3_column_int64(totals, 5))

        let daily = try statement("SELECT date(d.created_at, 'unixepoch', 'localtime'), SUM(d.word_count) FROM dictations d WHERE \(recognized) GROUP BY 1")
        defer { sqlite3_finalize(daily) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone; formatter.dateFormat = "yyyy-MM-dd"
        while sqlite3_step(daily) == SQLITE_ROW {
            if let day = text(daily, 0).flatMap(formatter.date(from:)) { result.daily[calendar.startOfDay(for: day)] = Int(sqlite3_column_int64(daily, 1)) }
        }
        result.totals.activeDays = result.daily.count
        let streak = Streaks.compute(activeDays: Set(result.daily.keys), today: now, calendar: calendar)
        result.currentStreak = streak.current; result.longestStreak = streak.longest

        let apps = try statement("SELECT COALESCE(d.app_bundle_id, 'unknown'), COALESCE(MAX(d.app_name), 'Unknown'), SUM(d.word_count) FROM dictations d WHERE \(recognized) GROUP BY 1 ORDER BY 3 DESC, 1 LIMIT 6")
        defer { sqlite3_finalize(apps) }
        while sqlite3_step(apps) == SQLITE_ROW {
            result.apps.append(AppUsage(bundleID: text(apps, 0) ?? "unknown", name: text(apps, 1) ?? "Unknown", words: Int(sqlite3_column_int64(apps, 2))))
        }
        let wpm = try statement("SELECT SUM(d.word_count), SUM(d.duration_seconds) FROM dictations d WHERE \(recognized) AND d.created_at >= ? AND d.duration_seconds > 0")
        defer { sqlite3_finalize(wpm) }
        bind(wpm, 1, now.addingTimeInterval(-30 * 86_400).timeIntervalSince1970)
        if sqlite3_step(wpm) == SQLITE_ROW {
            let seconds = sqlite3_column_double(wpm, 1)
            if seconds > 0 { result.wpm = Int((sqlite3_column_double(wpm, 0) / seconds * 60).rounded()) }
        }
        let outcomes = try statement("SELECT COALESCE(outcome, 'legacyRecognized'), COUNT(*) FROM dictations GROUP BY 1")
        defer { sqlite3_finalize(outcomes) }
        while sqlite3_step(outcomes) == SQLITE_ROW {
            result.outcomes[text(outcomes, 0) ?? "unknown"] = Int(sqlite3_column_int64(outcomes, 1))
        }
        return result
    }

    func aggregateExport() throws -> Data {
        let rows = try records()
        let snapshot = Self.snapshot(rows)
        func distribution(_ values: [Double]) -> [String: Any] {
            let sorted = values.filter { $0.isFinite && $0 >= 0 }.sorted()
            guard !sorted.isEmpty else { return ["samples": 0] }
            func percentile(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * p)) - 1)] }
            return ["samples": sorted.count, "p50Seconds": percentile(0.5), "p95Seconds": percentile(0.95)]
        }
        let metrics = rows.compactMap(\.metrics)
        var grouped: [String: [DictationOperationalMetrics]] = [:]
        for metric in metrics {
            var identity = [metric.modelVariant, metric.language ?? "unknown"]
            identity.append(String(metric.vocabularyTokenBudget ?? -1))
            identity.append(String(metric.decodingFallbackCount ?? -1))
            identity.append(metric.appVersion ?? "unknown")
            identity.append(metric.buildVersion ?? "unknown")
            identity.append(metric.dependencyVersion ?? "unknown")
            let durationBucket: String
            switch metric.rawAudioDuration {
            case ..<1.3: durationBucket = "short-under-1.3s"
            case ..<10: durationBucket = "1.3-to-10s"
            case ..<30: durationBucket = "10-to-30s"
            default: durationBucket = "30s-or-more"
            }
            identity.append(durationBucket)
            grouped[identity.joined(separator: "|"), default: []].append(metric)
        }
        var groups: [[String: Any]] = []
        for (key, values) in grouped.sorted(by: { $0.key < $1.key }) {
            var group: [String: Any] = ["configuration": key, "samples": values.count]
            group["releaseToCompletion"] = distribution(values.map(\.totalLatency))
            group["releaseToPasteDispatch"] = distribution(values.filter { $0.outcome == .pasteDispatched || $0.outcome == .verifiedDelivery }.map(\.totalLatency))
            group["transcription"] = distribution(values.compactMap(\.transcriptionDuration))
            group["transportReady"] = distribution(values.compactMap(\.transportReadyDuration))
            group["captureTail"] = distribution(values.compactMap(\.captureTailDuration))
            group["inputGaps"] = values.compactMap(\.inputGapCount).reduce(0, +)
            group["interruptedCaptures"] = values.filter { $0.captureInterrupted == true }.count
            group["modelLoading"] = distribution(values.compactMap(\.modelLoadingDuration))
            group["startup"] = distribution(values.compactMap(\.startupDuration))
            group["promptConstruction"] = distribution(values.compactMap(\.promptConstructionDuration))
            group["featureExtraction"] = distribution(values.compactMap(\.featureExtractionDuration))
            group["encoder"] = distribution(values.compactMap(\.encoderDuration))
            group["decoder"] = distribution(values.compactMap(\.decoderDuration))
            group["processing"] = distribution(values.compactMap(\.processingDuration))
            group["insertion"] = distribution(values.compactMap(\.insertionDuration))
            group["finalization"] = distribution(values.map(\.finalizationDuration))
            group["trimming"] = distribution(values.map(\.trimmingDuration))
            group["historyPersistence"] = distribution(values.compactMap(\.historyPersistenceDuration))
            let attempts = values.compactMap(\.decodingAttempts)
            group["decodingAttempts"] = ["samples": attempts.count, "total": attempts.reduce(0, +)]
            groups.append(group)
        }
        return try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "recognizedWords": snapshot.totals.words, "expandedWords": snapshot.totals.expandedWords,
            "recognizedDictations": snapshot.totals.dictations, "outcomes": snapshot.outcomes,
            "configurations": groups,
            "timingNote": "Elapsed application timings; paste dispatch is not verified visible delivery. No transcript, audio, vocabulary, app identifiers or clipboard content is exported."
        ], options: [.prettyPrinted, .sortedKeys])
    }
}

/// Pure streak arithmetic, separated from the database for testability.
enum Streaks {
    /// - Parameter activeDays: start-of-day dates with at least one dictation.
    static func compute(activeDays: Set<Date>, today: Date, calendar: Calendar = .current) -> (current: Int, longest: Int) {
        guard !activeDays.isEmpty else { return (0, 0) }

        let todayStart = calendar.startOfDay(for: today)

        // Current streak: count back from today, or from yesterday if today is
        // still empty (an empty today shouldn't zero the streak yet).
        var current = 0
        var cursor = todayStart
        if !activeDays.contains(cursor) {
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }
        while activeDays.contains(cursor) {
            current += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }

        // Longest streak: walk the sorted days.
        let sorted = activeDays.sorted()
        var longest = 1
        var run = 1
        for (previous, day) in zip(sorted, sorted.dropFirst()) {
            let gap = calendar.dateComponents([.day], from: previous, to: day).day ?? 0
            run = gap == 1 ? run + 1 : 1
            longest = max(longest, run)
        }
        return (current, longest)
    }
}
