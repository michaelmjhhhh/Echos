import XCTest
@testable import Echo

final class ReplacementProcessorTests: XCTestCase {
    private func processor(_ rules: [(String, String)]) -> ReplacementProcessor {
        ReplacementProcessor(rules: rules.compactMap {
            CompiledReplacementRule(misspelling: $0.0, word: $0.1)
        })
    }

    func testRuleSnapshotDoesNotChangeAfterSourceMutation() {
        var source = [("male", "mail")]
        let snapshot = source.compactMap {
            CompiledReplacementRule(misspelling: $0.0, word: $0.1)
        }
        let sut = ReplacementProcessor(rules: snapshot)
        source[0] = ("male", "email")
        XCTAssertEqual(sut.process("male"), "Mail")
    }

    func testReplacesWholeWordCaseInsensitively() {
        let sut = processor([("eric", "Erik")])
        XCTAssertEqual(sut.process("tell Eric about ERIC's plan"), "tell Erik about Erik's plan")
    }

    func testDoesNotFireInsideOtherWords() {
        let sut = processor([("eric", "Erik")])
        XCTAssertEqual(sut.process("a generic american dish"), "a generic american dish")
    }

    func testMultiWordMisspelling() {
        let sut = processor([("cooper netties", "Kubernetes")])
        XCTAssertEqual(sut.process("deploy it to cooper netties today"), "deploy it to Kubernetes today")
    }

    func testRegexMetacharactersAreEscaped() {
        let sut = processor([("node.js", "Node.js")])
        XCTAssertEqual(sut.process("we use node.js here"), "we use Node.js here")
        // The dot must not match "nodexjs" as a wildcard.
        XCTAssertEqual(sut.process("we use nodexjs here"), "we use nodexjs here")
    }

    func testLongerRulesWinOverShorterOverlaps() {
        // Store hands rules over longest-first; the processor must respect that order.
        let sut = processor([("cooper netties", "Kubernetes"), ("cooper", "Cooper")])
        XCTAssertEqual(
            sut.process("cooper met cooper netties"),
            "Cooper met Kubernetes"
        )
    }

    func testSentenceStartRecapitalizesLowercaseWords() {
        let sut = processor([("recieve", "receive")])
        XCTAssertEqual(sut.process("Recieve my thanks. recieve it well"), "Receive my thanks. Receive it well")
    }

    func testMidSentenceLowercaseWordsStayLowercase() {
        let sut = processor([("recieve", "receive")])
        XCTAssertEqual(sut.process("did you recieve the parcel"), "did you receive the parcel")
    }

    func testMixedCaseWordsInsertedVerbatimEvenAtSentenceStart() {
        let sut = processor([("i phone", "iPhone")])
        XCTAssertEqual(sut.process("I phone is great"), "iPhone is great")
    }

    func testMultipleOccurrencesInOneTranscript() {
        let sut = processor([("eric", "Erik")])
        XCTAssertEqual(sut.process("eric and eric and eric"), "Erik and Erik and Erik")
    }

    func testEmptyRulesPassThrough() {
        let sut = processor([])
        XCTAssertEqual(sut.process("unchanged text"), "unchanged text")
    }
}
