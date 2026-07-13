import XCTest
@testable import Echo

@MainActor
final class DictionaryStoreTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EchoTests-\(UUID().uuidString)", isDirectory: true)
        defaults = UserDefaults(suiteName: "EchoTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeStore(maxEntries: Int = DictionaryStore.defaultMaxEntries) -> DictionaryStore {
        DictionaryStore(directory: directory, maxEntries: maxEntries, defaults: defaults)
    }

    // MARK: - Adding & validation

    func testAddPersistsAcrossReload() {
        let store = makeStore()
        store.add(word: "Kubernetes", misspelling: "cooper netties", starred: true)
        store.add(word: "Erik")

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.entries.map(\.word), ["Erik", "Kubernetes"])
        XCTAssertEqual(reloaded.entries[1].misspelling, "cooper netties")
        XCTAssertTrue(reloaded.entries[1].isStarred)
        XCTAssertFalse(reloaded.entries[0].isStarred)
    }

    func testAddTrimsWhitespace() {
        let store = makeStore()
        let result = store.add(word: "  Erik  ", misspelling: "  eric  ")
        guard case .success(let entry) = result else { return XCTFail("Expected success") }
        XCTAssertEqual(entry.word, "Erik")
        XCTAssertEqual(entry.misspelling, "eric")
    }

    func testAddRejectsEmptyWord() {
        let store = makeStore()
        XCTAssertEqual(store.add(word: "   "), .failure(.empty))
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testAddRejectsCaseInsensitiveDuplicate() {
        let store = makeStore()
        store.add(word: "Kubernetes")
        XCTAssertEqual(store.add(word: "kubernetes"), .failure(.duplicate(existing: "Kubernetes")))
        XCTAssertEqual(store.entries.count, 1)
    }

    func testAddRejectsOverlongWord() {
        let store = makeStore()
        let longWord = String(repeating: "a", count: DictionaryStore.maxWordLength + 1)
        XCTAssertEqual(store.add(word: longWord), .failure(.tooLong))
    }

    func testAddRejectsMisspellingEqualToWord() {
        let store = makeStore()
        XCTAssertEqual(store.add(word: "Erik", misspelling: "erik"), .failure(.sameAsWord))
    }

    func testEmptyMisspellingBecomesNil() {
        let store = makeStore()
        let result = store.add(word: "Erik", misspelling: "   ")
        guard case .success(let entry) = result else { return XCTFail("Expected success") }
        XCTAssertNil(entry.misspelling)
    }

    func testCapRejectsWhenFull() {
        let store = makeStore(maxEntries: 2)
        store.add(word: "one")
        store.add(word: "two")
        XCTAssertEqual(store.add(word: "three"), .failure(.full))
        XCTAssertEqual(store.entries.count, 2)
    }

    // MARK: - Editing, deleting, starring

    func testUpdateChangesFieldsAndPersists() {
        let store = makeStore()
        guard case .success(var entry) = store.add(word: "Erik") else { return XCTFail() }
        entry.word = "Erika"
        entry.misspelling = "erica"
        entry.isStarred = true
        guard case .success = store.update(entry) else { return XCTFail("Update failed") }

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.entries.map(\.word), ["Erika"])
        XCTAssertEqual(reloaded.entries[0].misspelling, "erica")
        XCTAssertTrue(reloaded.entries[0].isStarred)
    }

    func testUpdateDoesNotCollideWithItself() {
        let store = makeStore()
        guard case .success(var entry) = store.add(word: "Erik", misspelling: "eric") else { return XCTFail() }
        entry.isStarred = true // word unchanged — must not be a "duplicate" of itself
        guard case .success = store.update(entry) else { return XCTFail("Self-collision") }
    }

    func testUpdateRejectsDuplicateOfOtherEntry() {
        let store = makeStore()
        store.add(word: "Kubernetes")
        guard case .success(var entry) = store.add(word: "Erik") else { return XCTFail() }
        entry.word = "KUBERNETES"
        XCTAssertEqual(store.update(entry), .failure(.duplicate(existing: "Kubernetes")))
    }

    func testDeleteRemovesEntry() {
        let store = makeStore()
        guard case .success(let entry) = store.add(word: "Erik") else { return XCTFail() }
        store.delete(entry.id)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(makeStore().entries.isEmpty)
    }

    func testToggleStar() {
        let store = makeStore()
        guard case .success(let entry) = store.add(word: "Erik") else { return XCTFail() }
        store.toggleStar(entry.id)
        XCTAssertTrue(store.entries[0].isStarred)
        store.toggleStar(entry.id)
        XCTAssertFalse(store.entries[0].isStarred)
    }

    // MARK: - Sorting & derived views

    func testSortOrders() {
        let store = makeStore()
        store.add(word: "banana")
        store.add(word: "Apple", starred: true)
        store.add(word: "cherry")
        // entries (newest first): cherry, Apple★, banana

        store.sort = .newest
        XCTAssertEqual(store.sortedEntries.map(\.word), ["cherry", "Apple", "banana"])
        store.sort = .oldest
        XCTAssertEqual(store.sortedEntries.map(\.word), ["banana", "Apple", "cherry"])
        store.sort = .alphabetical
        XCTAssertEqual(store.sortedEntries.map(\.word), ["Apple", "banana", "cherry"])
        store.sort = .starredFirst
        XCTAssertEqual(store.sortedEntries.map(\.word), ["Apple", "cherry", "banana"])
    }

    func testSortPersistsAcrossReload() {
        let store = makeStore()
        store.sort = .alphabetical
        XCTAssertEqual(makeStore().sort, .alphabetical)
    }

    func testPromptWordsStarredFirstThenNewest() {
        let store = makeStore()
        store.add(word: "old-plain")
        store.add(word: "old-star", starred: true)
        store.add(word: "new-plain")
        store.add(word: "new-star", starred: true)
        XCTAssertEqual(store.promptWords, ["new-star", "old-star", "new-plain", "old-plain"])
    }

    func testReplacementRulesLongestFirst() {
        let store = makeStore()
        store.add(word: "Kubernetes", misspelling: "cooper")
        store.add(word: "plain-word")
        store.add(word: "K8s cluster", misspelling: "cooper netties cluster")
        XCTAssertEqual(store.replacementRules.map(\.misspelling), ["cooper netties cluster", "cooper"])
        XCTAssertEqual(store.replacementRules.map(\.word), ["K8s cluster", "Kubernetes"])
    }

    func testCounts() {
        let store = makeStore()
        store.add(word: "one", starred: true)
        store.add(word: "two", misspelling: "too")
        store.add(word: "three")
        XCTAssertEqual(store.starredCount, 1)
        XCTAssertEqual(store.replacementCount, 1)
    }

    func testCompiledRulesRebuildAfterAddUpdateAndDelete() throws {
        let store = makeStore()
        let added = try store.add(word: "Kubernetes", misspelling: "cooper netties").get()
        XCTAssertEqual(
            ReplacementProcessor(rules: store.compiledReplacementRules).process("cooper netties"),
            "Kubernetes"
        )

        var edited = added
        edited.misspelling = "cube or netties"
        _ = store.update(edited)
        XCTAssertEqual(
            ReplacementProcessor(rules: store.compiledReplacementRules).process("cube or netties"),
            "Kubernetes"
        )

        store.delete(added.id)
        XCTAssertTrue(store.compiledReplacementRules.isEmpty)
    }

    func testCompiledRulesAreBuiltWhenPersistedEntriesLoad() {
        let store = makeStore()
        store.add(word: "Kubernetes", misspelling: "cooper netties")

        let reloaded = makeStore()
        XCTAssertEqual(
            ReplacementProcessor(rules: reloaded.compiledReplacementRules).process("cooper netties"),
            "Kubernetes"
        )
    }
}
