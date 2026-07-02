import XCTest
@testable import Echo

@MainActor
final class DictationControllerTests: XCTestCase {
    private var recorder: MockRecorder!
    private var transcriber: MockTranscriber!
    private var inserter: MockInserter!

    private func makeController() -> DictationController {
        recorder = MockRecorder()
        transcriber = MockTranscriber()
        inserter = MockInserter()
        let defaults = UserDefaults(suiteName: "EchoTests-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        return DictationController(
            settings: settings,
            recorder: recorder,
            transcriber: transcriber,
            inserter: inserter,
            hotkeyMonitor: MockHotkeyMonitor(),
            autostart: false
        )
    }

    func testPressIgnoredBeforeReady() {
        let controller = makeController()
        controller.hotkeyPressed()
        XCTAssertEqual(controller.state, .launching)
        XCTAssertFalse(recorder.isRecording)
    }

    func testPressStartsRecording() {
        let controller = makeController()
        controller.activateForTesting()
        controller.hotkeyPressed()
        XCTAssertEqual(controller.state, .recording)
        XCTAssertTrue(recorder.isRecording)
    }

    func testShortRecordingIsIgnored() async {
        let controller = makeController()
        controller.activateForTesting()
        recorder.samplesToReturn = [Float](repeating: 0, count: 100) // far below 0.3 s
        controller.hotkeyPressed()
        controller.hotkeyReleased()
        await controller.transcriptionTask?.value
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(inserter.insertedText)
    }

    func testFullPipelineInsertsProcessedText() async {
        let controller = makeController()
        controller.activateForTesting()
        recorder.samplesToReturn = [Float](repeating: 0, count: 16_000)
        transcriber.result = .success("  hello   world  ")
        controller.hotkeyPressed()
        controller.hotkeyReleased()
        await controller.transcriptionTask?.value
        XCTAssertEqual(inserter.insertedText, "hello world")
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(controller.lastTranscript, "hello world")
    }

    func testEmptyTranscriptInsertsNothing() async {
        let controller = makeController()
        controller.activateForTesting()
        recorder.samplesToReturn = [Float](repeating: 0, count: 16_000)
        transcriber.result = .success("   ")
        controller.hotkeyPressed()
        controller.hotkeyReleased()
        await controller.transcriptionTask?.value
        XCTAssertNil(inserter.insertedText)
        XCTAssertEqual(controller.state, .idle)
    }

    func testTranscriptionFailureShowsError() async {
        let controller = makeController()
        controller.activateForTesting()
        recorder.samplesToReturn = [Float](repeating: 0, count: 16_000)
        transcriber.result = .failure(TranscriptionError.modelNotLoaded)
        controller.hotkeyPressed()
        controller.hotkeyReleased()
        await controller.transcriptionTask?.value
        guard case .error = controller.state else {
            return XCTFail("Expected error state, got \(controller.state)")
        }
        XCTAssertNil(inserter.insertedText)
    }

    func testNoInsertionTargetOffersCopyInsteadOfPasting() async {
        let controller = makeController()
        controller.activateForTesting()
        recorder.samplesToReturn = [Float](repeating: 0, count: 16_000)
        transcriber.result = .success("hello world")
        inserter.hasInsertionTarget = false
        controller.hotkeyPressed()
        controller.hotkeyReleased()
        await controller.transcriptionTask?.value
        XCTAssertEqual(controller.state, .copyReady("hello world"))
        XCTAssertNil(inserter.insertedText)
    }

    func testCopyTranscriptCopiesText() async {
        let controller = makeController()
        controller.activateForTesting()
        recorder.samplesToReturn = [Float](repeating: 0, count: 16_000)
        transcriber.result = .success("hello world")
        inserter.hasInsertionTarget = false
        controller.hotkeyPressed()
        controller.hotkeyReleased()
        await controller.transcriptionTask?.value

        controller.copyTranscript()
        XCTAssertEqual(inserter.copiedText, "hello world")
        XCTAssertTrue(controller.copyConfirmed)
    }

    func testSecureInputBackstopOffersCopy() async {
        let controller = makeController()
        controller.activateForTesting()
        recorder.samplesToReturn = [Float](repeating: 0, count: 16_000)
        transcriber.result = .success("hello")
        inserter.resultToReturn = .copiedToClipboard
        controller.hotkeyPressed()
        controller.hotkeyReleased()
        await controller.transcriptionTask?.value
        XCTAssertEqual(controller.state, .copyReady("hello"))
    }

    func testNewDictationSupersedesCopyOffer() async {
        let controller = makeController()
        controller.activateForTesting()
        recorder.samplesToReturn = [Float](repeating: 0, count: 16_000)
        transcriber.result = .success("first")
        inserter.hasInsertionTarget = false
        controller.hotkeyPressed()
        controller.hotkeyReleased()
        await controller.transcriptionTask?.value
        XCTAssertEqual(controller.state, .copyReady("first"))

        controller.hotkeyPressed()
        XCTAssertEqual(controller.state, .recording)
    }

    func testUsageRecordedOnSuccessfulDictation() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EchoUsage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let usage = UsageStore(directory: directory)

        recorder = MockRecorder()
        transcriber = MockTranscriber()
        inserter = MockInserter()
        let defaults = UserDefaults(suiteName: "EchoTests-\(UUID().uuidString)")!
        let controller = DictationController(
            settings: SettingsStore(defaults: defaults),
            recorder: recorder,
            transcriber: transcriber,
            inserter: inserter,
            hotkeyMonitor: MockHotkeyMonitor(),
            usage: usage,
            autostart: false
        )
        controller.activateForTesting()
        recorder.samplesToReturn = [Float](repeating: 0, count: 32_000) // 2 s
        transcriber.result = .success("one two three")
        controller.hotkeyPressed()
        controller.hotkeyReleased()
        await controller.transcriptionTask?.value

        let totals = usage.totals()
        XCTAssertEqual(totals.dictations, 1)
        XCTAssertEqual(totals.words, 3)
    }

    func testQuickTapWithNoAudioIsSilentlyIgnored() {
        let controller = makeController()
        controller.activateForTesting()
        recorder.signalsCaptureReady = false
        recorder.samplesToReturn = []
        controller.hotkeyPressed()
        controller.hotkeyReleased()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(inserter.insertedText)
    }

    func testReleaseWithoutPressDoesNothing() {
        let controller = makeController()
        controller.activateForTesting()
        controller.hotkeyReleased()
        XCTAssertEqual(controller.state, .idle)
    }
}

// MARK: - Mocks

private final class MockRecorder: AudioRecording {
    var isRecording = false
    var samplesToReturn: [Float] = []
    var signalsCaptureReady = true
    var onLevel: ((Float) -> Void)?
    var onCaptureReady: (() -> Void)?

    func start(deviceUID: String?) throws {
        isRecording = true
        if signalsCaptureReady { onCaptureReady?() }
    }

    func stop() -> [Float] {
        isRecording = false
        return samplesToReturn
    }
}

private final class MockTranscriber: Transcribing {
    var result: Result<String, Error> = .success("")

    func prepare(progress: @escaping (Double) -> Void) async throws {}
    func loadModel() async throws {}

    func transcribe(_ samples: [Float]) async throws -> String {
        try result.get()
    }
}

private final class MockInserter: TextInserting {
    var insertedText: String?
    var copiedText: String?
    var hasInsertionTarget = true
    var resultToReturn: InsertionResult = .pasted

    @discardableResult
    func insert(_ text: String) -> InsertionResult {
        insertedText = text
        return resultToReturn
    }

    func copyToClipboard(_ text: String) {
        copiedText = text
    }
}

@MainActor
private final class MockHotkeyMonitor: HotkeyMonitoring {
    var hotkey: Hotkey = .rightOption
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?

    func start() {}
    func stop() {}
}
