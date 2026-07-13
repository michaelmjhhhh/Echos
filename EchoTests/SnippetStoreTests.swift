import XCTest
@testable import Echo

@MainActor
final class SnippetStoreTests: XCTestCase {
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

    private func makeStore(maxEntries: Int = SnippetStore.defaultMaxEntries) -> SnippetStore {
        SnippetStore(directory: directory, maxEntries: maxEntries)
    }

    // MARK: - Adding & validation

    func testAddPersistsAcrossReload() {
        let store = makeStore()
        store.add(trigger: "my email address", expansion: "jhmamichael@gmail.com")
        store.add(trigger: "my website", expansion: "michaelmjh.me")

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.entries.map(\.trigger), ["my website", "my email address"])
        XCTAssertEqual(reloaded.entries[1].expansion, "jhmamichael@gmail.com")
    }

    func testAddTrimsWhitespace() {
        let store = makeStore()
        store.add(trigger: "  my email address  ", expansion: "  jhmamichael@gmail.com  ")
        XCTAssertEqual(store.entries[0].trigger, "my email address")
        XCTAssertEqual(store.entries[0].expansion, "jhmamichael@gmail.com")
    }

    func testRejectsEmptyTrigger() {
        let store = makeStore()
        XCTAssertEqual(store.add(trigger: "   ", expansion: "text"), .failure(.emptyTrigger))
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testRejectsEmptyExpansion() {
        let store = makeStore()
        XCTAssertEqual(store.add(trigger: "my email", expansion: " "), .failure(.emptyExpansion))
    }

    func testRejectsOverlongTrigger() {
        let store = makeStore()
        let long = String(repeating: "a", count: SnippetStore.maxTriggerLength + 1)
        XCTAssertEqual(store.add(trigger: long, expansion: "text"), .failure(.triggerTooLong))
    }

    func testRejectsOverlongExpansion() {
        let store = makeStore()
        let long = String(repeating: "a", count: SnippetStore.maxExpansionLength + 1)
        XCTAssertEqual(store.add(trigger: "my essay", expansion: long), .failure(.expansionTooLong))
    }

    func testRejectsDuplicateTriggerCaseInsensitively() {
        let store = makeStore()
        store.add(trigger: "My Email", expansion: "a@b.c")
        XCTAssertEqual(
            store.add(trigger: "my email", expansion: "x@y.z"),
            .failure(.duplicate(existing: "My Email"))
        )
    }

    func testRejectsWhenFull() {
        let store = makeStore(maxEntries: 1)
        store.add(trigger: "one", expansion: "1")
        XCTAssertEqual(store.add(trigger: "two", expansion: "2"), .failure(.full))
    }

    // MARK: - Update & delete

    func testUpdateEditsInPlaceAndPersists() {
        let store = makeStore()
        guard case .success(var snippet) = store.add(trigger: "my email", expansion: "old@x.y") else {
            return XCTFail("add failed")
        }
        snippet.expansion = "new@x.y"
        XCTAssertNotNil(try? store.update(snippet).get())

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.entries[0].expansion, "new@x.y")
    }

    func testUpdateDoesNotCollideWithItself() {
        let store = makeStore()
        guard case .success(var snippet) = store.add(trigger: "my email", expansion: "a@b.c") else {
            return XCTFail("add failed")
        }
        snippet.expansion = "changed@b.c" // same trigger, must not be a duplicate of itself
        XCTAssertNotNil(try? store.update(snippet).get())
    }

    func testUpdateRejectsCollidingTrigger() {
        let store = makeStore()
        store.add(trigger: "my email", expansion: "a@b.c")
        guard case .success(var other) = store.add(trigger: "my site", expansion: "michaelmjh.me") else {
            return XCTFail("add failed")
        }
        other.trigger = "MY EMAIL"
        XCTAssertEqual(store.update(other), .failure(.duplicate(existing: "my email")))
    }

    func testDeleteRemovesAndPersists() {
        let store = makeStore()
        guard case .success(let snippet) = store.add(trigger: "my email", expansion: "a@b.c") else {
            return XCTFail("add failed")
        }
        store.delete(snippet.id)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(makeStore().entries.isEmpty)
    }

    // MARK: - Rules

    func testRulesAreLongestTriggerFirst() {
        let store = makeStore()
        store.add(trigger: "my email", expansion: "a@b.c")
        store.add(trigger: "my email signature", expansion: "Best, Michael")
        XCTAssertEqual(store.rules.map(\.trigger), ["my email signature", "my email"])
    }

    func testCompiledRulesRebuildAfterAddUpdateAndDelete() throws {
        let store = makeStore()
        let added = try store.add(trigger: "my site", expansion: "example.com").get()
        XCTAssertEqual(
            SnippetProcessor(rules: store.compiledRules).process("my site"),
            "example.com"
        )

        var edited = added
        edited.trigger = "my website"
        _ = store.update(edited)
        XCTAssertEqual(
            SnippetProcessor(rules: store.compiledRules).process("my website"),
            "example.com"
        )

        store.delete(added.id)
        XCTAssertTrue(store.compiledRules.isEmpty)
    }

    func testCompiledRulesAreBuiltWhenPersistedEntriesLoad() {
        let store = makeStore()
        store.add(trigger: "my site", expansion: "example.com")

        let reloaded = makeStore()
        XCTAssertEqual(
            SnippetProcessor(rules: reloaded.compiledRules).process("my site"),
            "example.com"
        )
    }
}
