import XCTest
@testable import Echo

final class VocabularyPromptTests: XCTestCase {
    /// Stand-in tokenizer: one "token" per character keeps budgets easy to reason about.
    private func charBudget(_ text: String) -> Int { text.count }

    func testJoinsAllWordsWhenBudgetAllows() {
        let text = VocabularyPrompt.text(for: ["Erik", "Kubernetes"], maxTokens: 100, budget: charBudget)
        XCTAssertEqual(text, "Erik, Kubernetes")
    }

    func testPreservesPriorityOrder() {
        let text = VocabularyPrompt.text(for: ["zeta", "alpha", "mid"], maxTokens: 100, budget: charBudget)
        XCTAssertEqual(text, "zeta, alpha, mid")
    }

    func testSkipsOverflowingWordButKeepsLaterOnesThatFit() {
        // "abcd" (4) fits; "toolongword" would push past 12; "ef" still fits after it.
        let text = VocabularyPrompt.text(for: ["abcd", "toolongword", "ef"], maxTokens: 12, budget: charBudget)
        XCTAssertEqual(text, "abcd, ef")
    }

    func testNeverTruncatesMidWord() {
        let text = VocabularyPrompt.text(for: ["abcdefghij"], maxTokens: 5, budget: charBudget)
        XCTAssertEqual(text, "")
    }

    func testEmptyInputProducesEmptyPrompt() {
        XCTAssertEqual(VocabularyPrompt.text(for: [], maxTokens: 10, budget: charBudget), "")
    }
}
