import Combine
import XCTest
@testable import Echo

@MainActor
final class DictationControllerTests: XCTestCase {
    private var recorder: MockRecorder!
    private var transcriber: MockTranscriber!
    private var inserter: MockInserter!
    private var settings: SettingsStore!

    private func makeController(transcriberFactory: ((String) -> Transcribing)? = nil) -> DictationController {
        recorder = MockRecorder()
        transcriber = MockTranscriber()
        inserter = MockInserter()
        let defaults = UserDefaults(suiteName: "EchoTests-\(UUID().uuidString)")!
        settings = SettingsStore(defaults: defaults)
        return DictationController(
            settings: settings,
            recorder: recorder,
            transcriber: transcriber,
            transcriberFactory: transcriberFactory,
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

    // MARK: - Dictionary integration

    private func makeControllerWithDictionary() -> (DictationController, DictionaryStore) {
        recorder = MockRecorder()
        transcriber = MockTranscriber()
        inserter = MockInserter()
        let suite = "EchoTests-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suite, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let dictionary = DictionaryStore(directory: directory, defaults: UserDefaults(suiteName: suite)!)
        let controller = DictationController(
            settings: SettingsStore(defaults: UserDefaults(suiteName: suite + "-settings")!),
            recorder: recorder,
            transcriber: transcriber,
            inserter: inserter,
            hotkeyMonitor: MockHotkeyMonitor(),
            dictionary: dictionary,
            autostart: false
        )
        return (controller, dictionary)
    }

    func testDictionaryVocabularyReachesTranscriber() async {
        let (controller, dictionary) = makeControllerWithDictionary()
        dictionary.add(word: "Kubernetes")
        dictionary.add(word: "Erik", starred: true)
        controller.activateForTesting()
        recorder.samplesToReturn = [Float](repeating: 0, count: 16_000)
        transcriber.result = .success("hello")
        controller.hotkeyPressed()
        controller.hotkeyReleased()
        await controller.transcriptionTask?.value
        XCTAssertEqual(transcriber.receivedVocabulary, ["Erik", "Kubernetes"]) // starred first
    }

    func testDictionaryReplacementAppliesToInsertedText() async {
        let (controller, dictionary) = makeControllerWithDictionary()
        dictionary.add(word: "Kubernetes", misspelling: "cooper netties")
        controller.activateForTesting()
        recorder.samplesToReturn = [Float](repeating: 0, count: 16_000)
        transcriber.result = .success("deploy to cooper netties now")
        controller.hotkeyPressed()
        controller.hotkeyReleased()
        await controller.transcriptionTask?.value
        XCTAssertEqual(inserter.insertedText, "deploy to Kubernetes now")
        XCTAssertEqual(controller.lastTranscript, "deploy to Kubernetes now")
    }

    func testEmptyDictionarySendsNoVocabulary() async {
        let (controller, _) = makeControllerWithDictionary()
        controller.activateForTesting()
        recorder.samplesToReturn = [Float](repeating: 0, count: 16_000)
        transcriber.result = .success("hello")
        controller.hotkeyPressed()
        controller.hotkeyReleased()
        await controller.transcriptionTask?.value
        XCTAssertEqual(transcriber.receivedVocabulary, [])
    }

    // MARK: - Model switching

    func testSwitchModelSwapsTranscriberAndPersistsVariant() async {
        let newMock = MockTranscriber()
        var requested: [String] = []
        let controller = makeController(transcriberFactory: { variant in
            requested.append(variant)
            return newMock
        })
        controller.activateForTesting()

        await controller.switchModel(to: "openai_whisper-base.en")

        XCTAssertEqual(requested, ["openai_whisper-base.en"])
        XCTAssertEqual(settings.modelVariant, "openai_whisper-base.en")
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.pendingModelVariant)

        // The next dictation must reach the new transcriber.
        recorder.samplesToReturn = [Float](repeating: 0, count: 16_000)
        newMock.result = .success("via new model")
        controller.hotkeyPressed()
        controller.hotkeyReleased()
        await controller.transcriptionTask?.value
        XCTAssertEqual(inserter.insertedText, "via new model")
    }

    func testSwitchModelIgnoredWhileRecording() async {
        var requested: [String] = []
        let controller = makeController(transcriberFactory: { variant in
            requested.append(variant)
            return MockTranscriber()
        })
        controller.activateForTesting()
        let originalVariant = settings.modelVariant
        controller.hotkeyPressed()

        await controller.switchModel(to: "openai_whisper-base.en")

        XCTAssertEqual(controller.state, .recording)
        XCTAssertEqual(settings.modelVariant, originalVariant)
        XCTAssertEqual(requested, [])
    }

    func testSwitchModelIgnoredForSameVariant() async {
        var requested: [String] = []
        let controller = makeController(transcriberFactory: { variant in
            requested.append(variant)
            return MockTranscriber()
        })
        controller.activateForTesting()

        await controller.switchModel(to: settings.modelVariant)

        XCTAssertEqual(requested, [])
        XCTAssertEqual(controller.state, .idle)
    }

    func testSwitchModelFailureRevertsToPreviousModel() async {
        let failing = MockTranscriber()
        failing.loadError = TranscriptionError.modelNotLoaded
        let reverted = MockTranscriber()
        var requested: [String] = []
        let controller = makeController(transcriberFactory: { variant in
            requested.append(variant)
            return variant == "openai_whisper-base.en" ? failing : reverted
        })
        controller.activateForTesting()
        let originalVariant = settings.modelVariant

        await controller.switchModel(to: "openai_whisper-base.en")

        XCTAssertEqual(requested, ["openai_whisper-base.en", originalVariant])
        XCTAssertEqual(settings.modelVariant, originalVariant)
        guard case .error = controller.state else {
            return XCTFail("Expected error state, got \(controller.state)")
        }
        XCTAssertNil(controller.pendingModelVariant)
    }

    func testSwitchModelDrivesDownloadAndLoadingStates() async {
        let newMock = MockTranscriber()
        newMock.progressToEmit = [0.5, 1.0]
        let controller = makeController(transcriberFactory: { _ in newMock })
        controller.activateForTesting()

        var states: [DictationState] = []
        let cancellable = controller.$state.sink { states.append($0) }
        defer { cancellable.cancel() }

        await controller.switchModel(to: "openai_whisper-base.en")

        XCTAssertTrue(states.contains { if case .downloadingModel = $0 { return true } else { return false } })
        XCTAssertTrue(states.contains { if case .loadingModel = $0 { return true } else { return false } })
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
    var receivedVocabulary: [String]?
    var prepareError: Error?
    var loadError: Error?
    var progressToEmit: [Double] = []

    func prepare(progress: @escaping (Double) -> Void) async throws {
        if let prepareError { throw prepareError }
        for value in progressToEmit { progress(value) }
    }

    func loadModel() async throws {
        if let loadError { throw loadError }
    }

    func transcribe(_ samples: [Float], vocabulary: [String]) async throws -> String {
        receivedVocabulary = vocabulary
        return try result.get()
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
