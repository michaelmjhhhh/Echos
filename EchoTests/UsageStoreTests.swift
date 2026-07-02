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
