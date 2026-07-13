import XCTest
@testable import Echo

@MainActor
final class TranscriptStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EchoTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testAddPersistsAcrossReload() async {
        let store = TranscriptStore(directory: directory)
        store.add("hello world")
        store.add("second entry")
        await store.flushPersistenceForTesting()

        let reloaded = TranscriptStore(directory: directory)
        XCTAssertEqual(reloaded.entries.map(\.text), ["second entry", "hello world"])
        XCTAssertEqual(reloaded.entries[1].wordCount, 2)
    }

    func testNewestFirstAndCapped() {
        let store = TranscriptStore(directory: directory, maxEntries: 3)
        for index in 1...5 {
            store.add("entry \(index)")
        }
        XCTAssertEqual(store.entries.map(\.text), ["entry 5", "entry 4", "entry 3"])
    }

    func testClearEmptiesMemoryAndDisk() async {
        let store = TranscriptStore(directory: directory)
        store.add("hello")
        store.clear()
        XCTAssertTrue(store.entries.isEmpty)
        await store.flushPersistenceForTesting()
        XCTAssertTrue(TranscriptStore(directory: directory).entries.isEmpty)
    }

    func testAddUpdatesMemoryBeforePersistenceCompletes() async {
        let persistence = SpyHistoryPersistence()
        let store = TranscriptStore(directory: directory, persistence: persistence)

        store.add("hello")

        XCTAssertEqual(store.entries.map(\.text), ["hello"])
        await store.flushPersistenceForTesting()
        let submissions = await persistence.submissions
        XCTAssertEqual(submissions.last?.entries.map(\.text), ["hello"])
    }

    func testRapidMutationsPersistNewestSnapshotLast() async {
        let persistence = SpyHistoryPersistence()
        let store = TranscriptStore(directory: directory, persistence: persistence)
        store.add("one")
        store.add("two")
        store.clear()

        await store.flushPersistenceForTesting()

        let submissions = await persistence.submissions
        XCTAssertEqual(submissions.map(\.revision), [1, 2, 3])
        XCTAssertEqual(submissions.last?.entries, [])
    }

    func testClearCannotBeOverwrittenByOlderPendingWrite() async {
        let store = TranscriptStore(directory: directory)
        for index in 0..<100 { store.add("entry \(index)") }
        store.clear()

        await store.flushPersistenceForTesting()

        XCTAssertTrue(TranscriptStore(directory: directory).entries.isEmpty)
    }

    func testTodayStats() {
        let store = TranscriptStore(directory: directory)
        store.add("one two three")
        store.add("four five")
        XCTAssertEqual(store.todayEntries.count, 2)
        XCTAssertEqual(store.todayWordCount, 5)
    }
}

private actor SpyHistoryPersistence: HistoryPersisting {
    struct Submission: Sendable {
        let revision: Int
        let entries: [TranscriptEntry]
    }

    private(set) var submissions: [Submission] = []

    func submit(entries: [TranscriptEntry], revision: Int) async {
        submissions.append(Submission(revision: revision, entries: entries))
    }

    func flush() async {}
}
