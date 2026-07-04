import XCTest
@testable import Echo

final class PolishPromptTests: XCTestCase {
    // MARK: - Gate

    func testShortTranscriptsAreNotPolished() {
        XCTAssertFalse(PolishPrompt.shouldPolish("send it now"))
        XCTAssertFalse(PolishPrompt.shouldPolish(""))
    }

    func testFourWordsOrMoreArePolished() {
        XCTAssertTrue(PolishPrompt.shouldPolish("please send it now"))
    }

    // MARK: - Token budget

    func testMaxTokensScalesWithInputLength() {
        XCTAssertEqual(PolishPrompt.maxTokens(for: "one two three four"), 4 * 2 + 48)
        let hundredWords = Array(repeating: "word", count: 100).joined(separator: " ")
        XCTAssertEqual(PolishPrompt.maxTokens(for: hundredWords), 100 * 2 + 48)
    }

    // MARK: - Output acceptance

    func testAcceptsFaithfulCleanup() {
        XCTAssertEqual(
            PolishPrompt.accepted(output: "Hello there, everyone.", input: "um hello there everyone"),
            "Hello there, everyone."
        )
    }

    func testTrimsAndUnwrapsQuotedOutput() {
        XCTAssertEqual(
            PolishPrompt.accepted(output: " \"Hello there, everyone.\" ", input: "um hello there everyone"),
            "Hello there, everyone."
        )
    }

    func testRejectsEmptyOutput() {
        XCTAssertNil(PolishPrompt.accepted(output: "   ", input: "um hello there everyone"))
    }

    func testRejectsOutputThatGrewTooMuch() {
        // 6 input words allow at most 6 × 1.3 + 10 = 17 output words.
        let bloated = Array(repeating: "word", count: 60).joined(separator: " ")
        XCTAssertNil(PolishPrompt.accepted(output: bloated, input: "what time is the meeting tomorrow"))
    }

    func testRejectsChatterPrefix() {
        XCTAssertNil(PolishPrompt.accepted(
            output: "Here is the cleaned text: Hello everyone.",
            input: "um hello everyone folks"
        ))
    }

    func testChatterPrefixAllowedWhenSpeakerSaidIt() {
        // "Here is..." is only chatter when the speaker didn't start that way.
        XCTAssertEqual(
            PolishPrompt.accepted(
                output: "Here is the plan for tomorrow.",
                input: "here is uh the plan for tomorrow"
            ),
            "Here is the plan for tomorrow."
        )
    }

    func testKeepsUnchangedTextUnchanged() {
        XCTAssertEqual(
            PolishPrompt.accepted(output: "Already clean text here.", input: "Already clean text here."),
            "Already clean text here."
        )
    }
}
