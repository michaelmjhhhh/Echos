import XCTest
@testable import Echo

final class TextProcessorTests: XCTestCase {
    private let processor = WhitespaceCleanupProcessor()

    func testTrimsSurroundingWhitespace() {
        XCTAssertEqual(processor.process("  hello world \n"), "hello world")
    }

    func testCollapsesInternalWhitespaceRuns() {
        XCTAssertEqual(processor.process("hello   world\n\ntwice"), "hello world twice")
    }

    func testEmptyAndWhitespaceOnlyBecomesEmpty() {
        XCTAssertEqual(processor.process(""), "")
        XCTAssertEqual(processor.process("   \n\t "), "")
    }

    func testCleanTextPassesThrough() {
        XCTAssertEqual(processor.process("Already clean."), "Already clean.")
    }
}
