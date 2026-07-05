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

    /// An already-downloaded model must prepare locally — no network, instant
    /// completion — so switching back to a downloaded model works offline.
    func testPrepareUsesLocalFolderWhenModelAlreadyDownloaded() async throws {
        // Deliberately fake variant: if prepare ever hits the network for it,
        // the download fails and so does the test.
        let variant = "echo-tests_fake-variant"
        try makeModelFolder(variant: variant, at: base)
        let service = TranscriptionService(modelVariant: variant, downloadBase: base)

        var reported: [Double] = []
        try await service.prepare { reported.append($0) }

        XCTAssertEqual(reported.last, 1)
        XCTAssertEqual(
            service.modelFolder?.path,
            WhisperModelPaths.modelFolder(for: variant, downloadBase: base).path
        )
    }
}
