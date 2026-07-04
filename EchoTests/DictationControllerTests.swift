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

    // MARK: - Polish integration

    private func makePolishController(
        polisher: Polishing,
        snippets: SnippetStore? = nil
    ) async -> DictationController {
        recorder = MockRecorder()
        transcriber = MockTranscriber()
        inserter = MockInserter()
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "EchoTests-\(UUID().uuidString)")!)
        settings.polishEnabled = true
        let polish = PolishManager(settings: settings, service: polisher)
        await polish.prepareTask?.value
        let controller = DictationController(
            settings: settings,
            recorder: recorder,
            transcriber: transcriber,
            inserter: inserter,
            hotkeyMonitor: MockHotkeyMonitor(),
            snippets: snippets,
            polish: polish,
            autostart: false
        )
        controller.activateForTesting()
        recorder.samplesToReturn = [Float](repeating: 0, count: 16_000)
        return controller
    }

    private func makeSnippetStore(trigger: String, expansion: String) -> SnippetStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EchoSnippets-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = SnippetStore(directory: directory)
        store.add(trigger: trigger, expansion: expansion)
        return store
    }

    func testPolishedTextIsInserted() async {
        let polisher = MockPolisher()
        polisher.result = .success("Hello there, everyone.")
        let controller = await makePolishController(polisher: polisher)
        transcriber.result = .success("um hello there everyone")
        controller.hotkeyPressed()
        controller.hotkeyReleased()
        await controller.transcriptionTask?.value
        XCTAssertEqual(inserter.insertedText, "Hello there, everyone.")
        XCTAssertEqual(polisher.polishedInputs, ["um hello there everyone"])
    }

    func testPolishErrorFallsBackToRawTranscript() async {
        let polisher = MockPolisher()
        polisher.result = .failure(PolishError.modelNotLoaded)
        let controller = await makePolishController(polisher: polisher)
        transcriber.result = .success("hello there everyone today")
        controller.hotkeyPressed()
        controller.hotkeyReleased()
        await controller.transcriptionTask?.value
        XCTAssertEqual(inserter.insertedText, "hello there everyone today")
        XCTAssertEqual(controller.state, .idle) // a polish failure is not a dictation error
    }

    func testPolishTimeoutFallsBackToRawTranscript() async {
        let polisher = MockPolisher()
        polisher.result = .success("too late")
        polisher.delay = .seconds(10)
        let controller = await makePolishController(polisher: polisher)
        controller.polishTimeoutSeconds = 0.05
        transcriber.result = .success("hello there everyone today")
        controller.hotkeyPressed()
        controller.hotkeyReleased()
        await controller.transcriptionTask?.value
        XCTAssertEqual(inserter.insertedText, "hello there everyone today")
    }

    func testRejectedPolishOutputFallsBackToRawTranscript() async {
        let polisher = MockPolisher()
        polisher.result = .success("Here is the cleaned text: hello everyone today")
        let controller = await makePolishController(polisher: polisher)
        transcriber.result = .success("hello there everyone today")
        controller.hotkeyPressed()
        controller.hotkeyReleased()
        await controller.transcriptionTask?.value
        XCTAssertEqual(inserter.insertedText, "hello there everyone today")
    }

    func testShortTranscriptSkipsPolish() async {
        let polisher = MockPolisher()
        let controller = await makePolishController(polisher: polisher)
        transcriber.result = .success("send it now")
        controller.hotkeyPressed()
        controller.hotkeyReleased()
        await controller.transcriptionTask?.value
        XCTAssertEqual(inserter.insertedText, "send it now")
        XCTAssertTrue(polisher.polishedInputs.isEmpty)
    }

    func testStandaloneSnippetBypassesPolish() async {
        let polisher = MockPolisher()
        let snippets = makeSnippetStore(trigger: "my email address", expansion: "jhmamichael@gmail.com")
        let controller = await makePolishController(polisher: polisher, snippets: snippets)
        transcriber.result = .success("My email address.")
        controller.hotkeyPressed()
        controller.hotkeyReleased()
        await controller.transcriptionTask?.value
        XCTAssertEqual(inserter.insertedText, "jhmamichael@gmail.com")
        XCTAssertTrue(polisher.polishedInputs.isEmpty)
    }

    func testMidSentenceSnippetExpandsAfterPolish() async {
        let polisher = MockPolisher()
        polisher.result = .success("Send it to my email, please.")
        let snippets = makeSnippetStore(trigger: "my email", expansion: "jhmamichael@gmail.com")
        let controller = await makePolishController(polisher: polisher, snippets: snippets)
        transcriber.result = .success("um send it to my email please")
        controller.hotkeyPressed()
        controller.hotkeyReleased()
        await controller.transcriptionTask?.value
        XCTAssertEqual(polisher.polishedInputs, ["um send it to my email please"])
        XCTAssertEqual(inserter.insertedText, "Send it to jhmamichael@gmail.com, please.")
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

    func prepare(progress: @escaping (Double) -> Void) async throws {}
    func loadModel() async throws {}

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

private final class MockPolisher: Polishing {
    var result: Result<String, Error> = .success("")
    var delay: Duration = .zero
    var polishedInputs: [String] = []

    func prepare(progress: @escaping (Double) -> Void) async throws {}
    func unload() {}

    func polish(_ text: String) async throws -> String {
        polishedInputs.append(text)
        if delay > .zero { try await Task.sleep(for: delay) }
        return try result.get()
    }
}
