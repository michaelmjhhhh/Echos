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

    func testAddPersistsAcrossReload() {
        let store = TranscriptStore(directory: directory)
        store.add("hello world")
        store.add("second entry")

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

    func testClearEmptiesMemoryAndDisk() {
        let store = TranscriptStore(directory: directory)
        store.add("hello")
        store.clear()
        XCTAssertTrue(store.entries.isEmpty)
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
