import XCTest
@testable import Echo

final class TranscriptionServiceTests: XCTestCase {
    private var base: URL!

    override func setUp() {
        super.setUp()
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("EchoTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: base)
        super.tearDown()
    }

    /// An unknown variant cannot become installed merely by creating structural
    /// placeholder files. Preparation rejects it before any network acquisition.
    func testPrepareRejectsUnknownVariantWithoutPublishingReadiness() async throws {
        let variant = "echo-tests_fake-variant"
        try makeModelFolder(variant: variant, at: base)
        let service = TranscriptionService(modelVariant: variant, downloadBase: base)
        var reported: [Double] = []

        do {
            try await service.prepare { reported.append($0) }
            XCTFail("An unknown model variant must not be accepted as installed")
        } catch ModelInstallationError.unknownVariant {
            // This local catalog rejection occurs before model or tokenizer download.
        } catch {
            XCTFail("Unexpected preparation error: \(error)")
        }

        XCTAssertTrue(reported.isEmpty)
        XCTAssertNil(service.modelFolder)
    }
}
