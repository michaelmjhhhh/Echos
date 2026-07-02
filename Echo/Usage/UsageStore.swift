import AppKit
import SQLite3

struct UsageTotals: Equatable {
    var words = 0
    var dictations = 0
    var wordsThisMonth = 0
    var activeDays = 0
}

struct AppUsage: Identifiable, Equatable {
    let bundleID: String
    let name: String
    let words: Int

    var id: String { bundleID }
}

/// Permanent, local-only dictation statistics in SQLite. Stores counts and
/// timings — never transcript text — so Insights works even with history off.
@MainActor
final class UsageStore: ObservableObject {
    /// Bumped on every write so views know to re-run their queries.
    @Published private(set) var revision = 0

    private var db: OpaquePointer?

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Echo", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let path = base.appendingPathComponent("usage.sqlite").path

        guard sqlite3_open(path, &db) == SQLITE_OK else {
            sqlite3_close(db)
            db = nil
            return
        }
        exec("""
            CREATE TABLE IF NOT EXISTS dictations (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              created_at REAL NOT NULL,
              word_count INTEGER NOT NULL,
              duration_seconds REAL NOT NULL,
              latency_seconds REAL,
              app_bundle_id TEXT,
              app_name TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_dictations_created ON dictations(created_at);
            """)
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Writing

    func record(
        words: Int,
        duration: TimeInterval,
        latency: TimeInterval?,
        appBundleID: String?,
        appName: String?,
        date: Date = Date()
    ) {
        guard let statement = prepare("""
            INSERT INTO dictations (created_at, word_count, duration_seconds, latency_seconds, app_bundle_id, app_name)
            VALUES (?, ?, ?, ?, ?, ?)
            """) else { return }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
        sqlite3_bind_int64(statement, 2, Int64(words))
        sqlite3_bind_double(statement, 3, duration)
        if let latency {
            sqlite3_bind_double(statement, 4, latency)
        } else {
            sqlite3_bind_null(statement, 4)
        }
        bindText(statement, 5, appBundleID)
        bindText(statement, 6, appName)

        if sqlite3_step(statement) == SQLITE_DONE {
            revision += 1
        }
    }

    // MARK: - Queries

    func totals(now: Date = Date(), calendar: Calendar = .current) -> UsageTotals {
        var totals = UsageTotals()
        if let statement = prepare("SELECT COALESCE(SUM(word_count), 0), COUNT(*), COUNT(DISTINCT date(created_at, 'unixepoch', 'localtime')) FROM dictations") {
            defer { sqlite3_finalize(statement) }
            if sqlite3_step(statement) == SQLITE_ROW {
                totals.words = Int(sqlite3_column_int64(statement, 0))
                totals.dictations = Int(sqlite3_column_int64(statement, 1))
                totals.activeDays = Int(sqlite3_column_int64(statement, 2))
            }
        }
        let monthStart = calendar.date(
            from: calendar.dateComponents([.year, .month], from: now)
        ) ?? now
        if let statement = prepare("SELECT COALESCE(SUM(word_count), 0) FROM dictations WHERE created_at >= ?") {
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, monthStart.timeIntervalSince1970)
            if sqlite3_step(statement) == SQLITE_ROW {
                totals.wordsThisMonth = Int(sqlite3_column_int64(statement, 0))
            }
        }
        return totals
    }

    /// Aggregate words-per-minute of speech over the trailing window.
    func averageWPM(days: Int = 30, now: Date = Date()) -> Int {
        let since = now.addingTimeInterval(-Double(days) * 86_400)
        guard let statement = prepare("""
            SELECT COALESCE(SUM(word_count), 0), COALESCE(SUM(duration_seconds), 0)
            FROM dictations WHERE created_at >= ? AND duration_seconds > 0
            """) else { return 0 }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, since.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        let words = Double(sqlite3_column_int64(statement, 0))
        let seconds = sqlite3_column_double(statement, 1)
        guard seconds > 0 else { return 0 }
        return Int((words / (seconds / 60)).rounded())
    }

    func perAppWords(limit: Int = 6) -> [AppUsage] {
        guard let statement = prepare("""
            SELECT COALESCE(app_bundle_id, 'unknown'), COALESCE(MAX(app_name), 'Unknown'), SUM(word_count) AS w
            FROM dictations GROUP BY 1 ORDER BY w DESC LIMIT ?
            """) else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(limit))
        var result: [AppUsage] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(AppUsage(
                bundleID: columnText(statement, 0) ?? "unknown",
                name: columnText(statement, 1) ?? "Unknown",
                words: Int(sqlite3_column_int64(statement, 2))
            ))
        }
        return result
    }

    /// Words per local calendar day (start-of-day keys), for the heatmap.
    func dailyWords(since: Date, calendar: Calendar = .current) -> [Date: Int] {
        guard let statement = prepare("""
            SELECT date(created_at, 'unixepoch', 'localtime') AS day, SUM(word_count)
            FROM dictations WHERE created_at >= ? GROUP BY day
            """) else { return [:] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, since.timeIntervalSince1970)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone

        var result: [Date: Int] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let dayString = columnText(statement, 0),
                  let day = formatter.date(from: dayString) else { continue }
            result[calendar.startOfDay(for: day)] = Int(sqlite3_column_int64(statement, 1))
        }
        return result
    }

    // MARK: - SQLite helpers

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        guard db != nil else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        return statement
    }

    private func bindText(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        if let value {
            sqlite3_bind_text(statement, index, value, -1, transient)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
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
