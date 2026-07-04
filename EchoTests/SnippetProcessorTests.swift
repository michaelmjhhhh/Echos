import XCTest
@testable import Echo

final class SnippetProcessorTests: XCTestCase {
    private func processor(_ rules: [(String, String)]) -> SnippetProcessor {
        SnippetProcessor(rulesProvider: { rules.map { (trigger: $0.0, expansion: $0.1) } })
    }

    // MARK: - Standalone utterances

    func testStandaloneTriggerExpands() {
        let sut = processor([("my email address", "jhmamichael@gmail.com")])
        XCTAssertEqual(sut.process("my email address"), "jhmamichael@gmail.com")
    }

    func testStandaloneTriggerWithTrailingPunctuationExpands() {
        let sut = processor([("my email address", "jhmamichael@gmail.com")])
        XCTAssertEqual(sut.process("My email address."), "jhmamichael@gmail.com")
        XCTAssertEqual(sut.process(" my email address! "), "jhmamichael@gmail.com")
    }

    func testStandaloneExpansionKeepsSavedCasingVerbatim() {
        let sut = processor([("rewrite prompt", "Rewrite this to be more concise.")])
        XCTAssertEqual(sut.process("REWRITE PROMPT"), "Rewrite this to be more concise.")
    }

    // MARK: - Mid-sentence

    func testMidSentenceTriggerExpandsInPlace() {
        let sut = processor([("my address", "123 Main Street, San Francisco")])
        XCTAssertEqual(
            sut.process("Send the package to my address today."),
            "Send the package to 123 Main Street, San Francisco today."
        )
    }

    func testMatchesCaseInsensitivelyMidSentence() {
        let sut = processor([("my website", "michaelmjh.me")])
        XCTAssertEqual(sut.process("check out My Website please"), "check out michaelmjh.me please")
    }

    func testExpansionNeverRecapitalized() {
        // Expansions are literal content — even at a sentence start they must
        // be inserted verbatim (an email address must stay lowercase).
        let sut = processor([("my email address", "jhmamichael@gmail.com")])
        XCTAssertEqual(
            sut.process("Sure. my email address works best."),
            "Sure. jhmamichael@gmail.com works best."
        )
    }

    func testDoesNotFireInsideOtherWords() {
        let sut = processor([("my email address", "jhmamichael@gmail.com")])
        XCTAssertEqual(
            sut.process("we were my email addressing the crowd"),
            "we were my email addressing the crowd"
        )
    }

    func testReplacesAllOccurrences() {
        let sut = processor([("my site", "michaelmjh.me")])
        XCTAssertEqual(
            sut.process("my site is my site"),
            "michaelmjh.me is michaelmjh.me"
        )
    }

    func testLongerTriggersWinOverShorterOverlaps() {
        // Store hands rules over longest-first; the processor must respect that order.
        let sut = processor([
            ("my email signature", "Best,\nMichael"),
            ("my email", "jhmamichael@gmail.com"),
        ])
        XCTAssertEqual(
            sut.process("add my email signature after my email"),
            "add Best,\nMichael after jhmamichael@gmail.com"
        )
    }

    func testRegexMetacharactersInTriggerAreEscaped() {
        let sut = processor([("c++ snippet", "std::cout << x;")])
        XCTAssertEqual(sut.process("paste the c++ snippet here"), "paste the std::cout << x; here")
    }

    func testNoRulesLeavesTextUntouched() {
        let sut = processor([])
        XCTAssertEqual(sut.process("nothing to see here."), "nothing to see here.")
    }

    // MARK: - Pipeline ordering

    func testDictionaryReplacementFeedsSnippetTrigger() {
        // Whisper heard "male" for "mail"; the dictionary fixes it, then the
        // snippet fires — this is why ReplacementProcessor must run first.
        let replacement = ReplacementProcessor(rulesProvider: { [(misspelling: "male", word: "mail")] })
        let snippet = SnippetProcessor(rulesProvider: { [(trigger: "my mail", expansion: "jhmamichael@gmail.com")] })
        let processors: [TextProcessor] = [WhitespaceCleanupProcessor(), replacement, snippet]

        var text = "send it to my male please"
        for processor in processors { text = processor.process(text) }
        XCTAssertEqual(text, "send it to jhmamichael@gmail.com please")
    }
}
