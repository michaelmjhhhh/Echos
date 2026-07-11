import SQLite3
import XCTest
@testable import Echo

@MainActor
final class UsageStoreTests: XCTestCase {
    private var directory: URL!
    private let calendar = Calendar.current

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EchoUsage-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func day(_ offset: Int, from reference: Date = Date()) -> Date {
        calendar.date(byAdding: .day, value: offset, to: reference)!
    }

    private func metrics(outcome: DictationOutcome = .success) -> DictationOperationalMetrics {
        DictationOperationalMetrics(
            rawAudioDuration: 2,
            selectedAudioDuration: 1.5,
            finalizationDuration: 0.02,
            trimmingDuration: 0.001,
            transcriptionDuration: outcome == .transcriptionFailure ? nil : 0.45,
            totalLatency: 0.5,
            trimmingApplied: true,
            droppedBufferCount: 1,
            finalizationTimedOut: false,
            modelVariant: "test-model",
            outcome: outcome
        )
    }

    private func createLegacyDatabase() {
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("usage.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, """
            CREATE TABLE dictations (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              created_at REAL NOT NULL,
              word_count INTEGER NOT NULL,
              duration_seconds REAL NOT NULL,
              latency_seconds REAL,
              app_bundle_id TEXT,
              app_name TEXT
            );
            INSERT INTO dictations
              (created_at, word_count, duration_seconds, latency_seconds, app_bundle_id, app_name)
            VALUES
              (strftime('%s', 'now'), 4, 2, 0.4, 'legacy.app', 'Legacy');
            """, nil, nil, nil), SQLITE_OK)
    }

    func testRecordAndTotalsPersistAcrossReload() {
        let store = UsageStore(directory: directory)
        store.record(words: 10, duration: 5, latency: 1.0, appBundleID: "com.apple.TextEdit", appName: "TextEdit")
        store.record(words: 20, duration: 8, latency: nil, appBundleID: "com.apple.Safari", appName: "Safari")

        let reloaded = UsageStore(directory: directory)
        let totals = reloaded.totals()
        XCTAssertEqual(totals.words, 30)
        XCTAssertEqual(totals.dictations, 2)
        XCTAssertEqual(totals.activeDays, 1)
        XCTAssertEqual(totals.wordsThisMonth, 30)
    }

    func testLegacySchemaMigratesAndPreservesTotals() {
        createLegacyDatabase()
        let store = UsageStore(directory: directory)

        XCTAssertEqual(store.totals().dictations, 1)
        XCTAssertEqual(store.totals().words, 4)
        store.record(
            words: 3,
            duration: 2,
            latency: 0.5,
            appBundleID: nil,
            appName: nil,
            metrics: metrics()
        )
        XCTAssertEqual(store.totals().dictations, 2)
        XCTAssertEqual(store.totals().words, 7)
        XCTAssertEqual(store.latestOperationalMetricsForTesting(), metrics())
    }

    func testFailedOperationalRowsDoNotAffectInsights() {
        let store = UsageStore(directory: directory)
        store.record(
            words: 5,
            duration: 2,
            latency: 0.5,
            appBundleID: "success.app",
            appName: "Success",
            metrics: metrics()
        )
        store.record(
            words: 99,
            duration: 2,
            latency: 0.5,
            appBundleID: "failure.app",
            appName: "Failure",
            metrics: metrics(outcome: .transcriptionFailure)
        )

        XCTAssertEqual(store.totals().dictations, 1)
        XCTAssertEqual(store.totals().words, 5)
        XCTAssertEqual(store.averageWPM(), 150)
        XCTAssertEqual(store.perAppWords().map(\.bundleID), ["success.app"])
        let today = Calendar.current.startOfDay(for: Date())
        XCTAssertEqual(store.dailyWords(since: Date().addingTimeInterval(-60))[today], 5)
    }

    func testOperationalSchemaContainsNoContentOrDeviceColumns() {
        _ = UsageStore(directory: directory)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("usage.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "PRAGMA table_info(dictations)", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        var names: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            names.append(String(cString: sqlite3_column_text(statement, 1)))
        }
        let expected: Set<String> = [
            "id", "created_at", "word_count", "duration_seconds", "latency_seconds",
            "app_bundle_id", "app_name", "raw_audio_seconds", "selected_audio_seconds",
            "finalization_seconds", "trimming_seconds", "transcription_seconds",
            "total_latency_seconds", "trimming_applied", "conversion_drop_count",
            "finalization_timed_out", "model_variant", "outcome"
        ]
        XCTAssertEqual(Set(names), expected)
    }

    func testAverageWPM() {
        let store = UsageStore(directory: directory)
        store.record(words: 60, duration: 30, latency: nil, appBundleID: nil, appName: nil)
        store.record(words: 30, duration: 30, latency: nil, appBundleID: nil, appName: nil)
        // 90 words over 60 seconds of speech = 90 WPM
        XCTAssertEqual(store.averageWPM(), 90)
    }

    func testAverageWPMEmptyIsZero() {
        XCTAssertEqual(UsageStore(directory: directory).averageWPM(), 0)
    }

    func testPerAppWordsOrdersByVolume() {
        let store = UsageStore(directory: directory)
        store.record(words: 5, duration: 2, latency: nil, appBundleID: "a", appName: "Alpha")
        store.record(words: 50, duration: 20, latency: nil, appBundleID: "b", appName: "Beta")
        store.record(words: 10, duration: 4, latency: nil, appBundleID: "a", appName: "Alpha")

        let apps = store.perAppWords()
        XCTAssertEqual(apps.map(\.name), ["Beta", "Alpha"])
        XCTAssertEqual(apps.map(\.words), [50, 15])
    }

    func testDailyWordsGroupsByLocalDay() {
        let store = UsageStore(directory: directory)
        let today = Date()
        store.record(words: 10, duration: 5, latency: nil, appBundleID: nil, appName: nil, date: today)
        store.record(words: 15, duration: 5, latency: nil, appBundleID: nil, appName: nil, date: today)
        store.record(words: 7, duration: 5, latency: nil, appBundleID: nil, appName: nil, date: day(-1))

        let daily = store.dailyWords(since: day(-3))
        XCTAssertEqual(daily[calendar.startOfDay(for: today)], 25)
        XCTAssertEqual(daily[calendar.startOfDay(for: day(-1))], 7)
    }
}

final class StreaksTests: XCTestCase {
    private let calendar = Calendar.current

    private func days(_ offsets: [Int]) -> Set<Date> {
        let today = calendar.startOfDay(for: Date())
        return Set(offsets.map { calendar.date(byAdding: .day, value: $0, to: today)! })
    }

    func testEmpty() {
        let result = Streaks.compute(activeDays: [], today: Date())
        XCTAssertEqual(result.current, 0)
        XCTAssertEqual(result.longest, 0)
    }

    func testCurrentStreakIncludingToday() {
        let result = Streaks.compute(activeDays: days([0, -1, -2]), today: Date())
        XCTAssertEqual(result.current, 3)
        XCTAssertEqual(result.longest, 3)
    }

    func testEmptyTodayDoesNotBreakStreak() {
        let result = Streaks.compute(activeDays: days([-1, -2]), today: Date())
        XCTAssertEqual(result.current, 2)
    }

    func testGapResetsCurrentButKeepsLongest() {
        let result = Streaks.compute(activeDays: days([0, -3, -4, -5, -6]), today: Date())
        XCTAssertEqual(result.current, 1)
        XCTAssertEqual(result.longest, 4)
    }
}
