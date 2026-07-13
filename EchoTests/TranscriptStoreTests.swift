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

    func testNewestFirstAndCapped() async {
        let store = TranscriptStore(directory: directory, maxEntries: 3)
        for index in 1...5 {
            store.add("entry \(index)")
        }
        XCTAssertEqual(store.entries.map(\.text), ["entry 5", "entry 4", "entry 3"])
        await store.flushPersistenceForTesting()
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

    func testVisibleHistoryDoesNotWaitForBlockedPersistence() async {
        let persistence = GatedHistoryPersistence()
        let store = TranscriptStore(directory: directory, persistence: persistence)

        store.add("hello")
        await persistence.waitUntilSubmitStarts()

        XCTAssertEqual(store.entries.map(\.text), ["hello"])
        let finishedWhileBlocked = await persistence.didFinish
        XCTAssertFalse(finishedWhileBlocked)

        await persistence.release()
        await store.flushPersistenceForTesting()
        let finishedAfterRelease = await persistence.didFinish
        XCTAssertTrue(finishedAfterRelease)
    }

    func testPersistenceFailureDoesNotRollBackVisibleHistory() async {
        let persistence = FailingHistoryPersistence()
        let store = TranscriptStore(directory: directory, persistence: persistence)

        store.add("hello")
        await store.flushPersistenceForTesting()

        XCTAssertEqual(store.entries.map(\.text), ["hello"])
        let submissionCount = await persistence.submissionCount
        XCTAssertEqual(submissionCount, 1)
    }

    func testClearCannotBeOverwrittenByOlderPendingWrite() async {
        let store = TranscriptStore(directory: directory)
        for index in 0..<100 { store.add("entry \(index)") }
        store.clear()

        await store.flushPersistenceForTesting()

        XCTAssertTrue(TranscriptStore(directory: directory).entries.isEmpty)
    }

    func testTodayStats() async {
        let store = TranscriptStore(directory: directory)
        store.add("one two three")
        store.add("four five")
        XCTAssertEqual(store.todayEntries.count, 2)
        XCTAssertEqual(store.todayWordCount, 5)
        await store.flushPersistenceForTesting()
    }
}

private actor GatedHistoryPersistence: HistoryPersisting {
    private var started = false
    private(set) var didFinish = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func submit(entries: [TranscriptEntry], revision: Int) async {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { releaseWaiter = $0 }
        didFinish = true
    }

    func waitUntilSubmitStarts() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    func flush() async {}
}

private actor FailingHistoryPersistence: HistoryPersisting {
    private(set) var submissionCount = 0

    func submit(entries: [TranscriptEntry], revision: Int) async {
        submissionCount += 1
        // Simulate an encoder or disk writer that cannot persist the snapshot.
    }

    func flush() async {}
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
