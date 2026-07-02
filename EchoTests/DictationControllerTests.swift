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
        settings.playSounds = false
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

    func testBlockedPasteSurfacesClipboardFallback() async {
        let controller = makeController()
        controller.activateForTesting()
        recorder.samplesToReturn = [Float](repeating: 0, count: 16_000)
        transcriber.result = .success("hello")
        inserter.resultToReturn = .copiedToClipboard
        controller.hotkeyPressed()
        controller.hotkeyReleased()
        await controller.transcriptionTask?.value
        guard case .error(let message) = controller.state else {
            return XCTFail("Expected error state, got \(controller.state)")
        }
        XCTAssertTrue(message.contains("clipboard"))
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
    var onLevel: ((Float) -> Void)?

    func start(deviceUID: String?) throws { isRecording = true }

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
    var resultToReturn: InsertionResult = .pasted

    @discardableResult
    func insert(_ text: String) -> InsertionResult {
        insertedText = text
        return resultToReturn
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
