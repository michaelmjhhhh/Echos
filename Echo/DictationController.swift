import AppKit
import Combine

@MainActor
final class DictationController: ObservableObject {
    @Published private(set) var state: DictationState = .launching
    @Published private(set) var lastTranscript: String = ""
    /// Live microphone level (0...1) while recording, drives the overlay waveform.
    @Published private(set) var audioLevel: Float = 0

    private let settings: SettingsStore
    private let recorder: AudioRecording
    private let transcriber: Transcribing
    private let inserter: TextInserting
    private let processors: [TextProcessor]
    private var hotkeyMonitor: HotkeyMonitoring
    private var overlay: OverlayController?
    private var maxDurationTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    /// Recordings shorter than this are treated as accidental taps.
    private let minimumSampleCount = Int(0.3 * Double(AudioRecorder.sampleRate))
    /// Auto-stop cap so a stuck key can't record forever.
    private let maxRecordingSeconds: Double = 120

    /// Exposed so tests (and the UI, if ever needed) can await the in-flight transcription.
    private(set) var transcriptionTask: Task<Void, Never>?

    init(
        settings: SettingsStore = .shared,
        recorder: AudioRecording = AudioRecorder(),
        transcriber: Transcribing? = nil,
        inserter: TextInserting = TextInserter(),
        processors: [TextProcessor] = [WhitespaceCleanupProcessor()],
        hotkeyMonitor: HotkeyMonitoring? = nil,
        autostart: Bool = true
    ) {
        self.settings = settings
        self.recorder = recorder
        self.transcriber = transcriber ?? TranscriptionService(modelVariant: settings.modelVariant)
        self.inserter = inserter
        self.processors = processors
        self.hotkeyMonitor = hotkeyMonitor ?? HotkeyMonitor()

        self.hotkeyMonitor.onKeyDown = { [weak self] in self?.hotkeyPressed() }
        self.hotkeyMonitor.onKeyUp = { [weak self] in self?.hotkeyReleased() }

        self.recorder.onLevel = { [weak self] level in
            Task { @MainActor in self?.audioLevel = level }
        }

        settings.$hotkey
            .removeDuplicates()
            .sink { [weak self] hotkey in self?.hotkeyMonitor.hotkey = hotkey }
            .store(in: &cancellables)

        let isHostingTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if autostart && !isHostingTests {
            let overlay = OverlayController()
            self.overlay = overlay
            $state.combineLatest($audioLevel)
                .sink { state, level in overlay.update(state: state, level: level) }
                .store(in: &cancellables)
            Task { await start() }
        }
    }

    func start() async {
        await waitForPermissions()
        do {
            state = .downloadingModel(progress: 0)
            try await transcriber.prepare { [weak self] progress in
                Task { @MainActor in
                    guard let self, case .downloadingModel = self.state else { return }
                    self.state = .downloadingModel(progress: progress)
                }
            }
            state = .loadingModel
            try await transcriber.loadModel()
        } catch {
            state = .error("Model setup failed: \(error.localizedDescription)")
            return
        }
        hotkeyMonitor.hotkey = settings.hotkey
        hotkeyMonitor.start()
        state = .idle
    }

    /// Test seam: arms the controller without permission checks or model loading.
    func activateForTesting() {
        state = .idle
    }

    // MARK: - Permissions

    private func waitForPermissions() async {
        _ = await Permissions.requestMicrophone()
        if !Permissions.accessibilityGranted {
            Permissions.promptForAccessibility()
        }
        while !(Permissions.microphoneGranted && Permissions.accessibilityGranted) {
            state = .needsPermissions(
                microphone: Permissions.microphoneGranted,
                accessibility: Permissions.accessibilityGranted
            )
            try? await Task.sleep(for: .seconds(1))
        }
    }

    // MARK: - Recording lifecycle

    func hotkeyPressed() {
        guard case .idle = state else { return }
        do {
            try recorder.start(deviceUID: settings.inputDeviceUID)
        } catch {
            state = .error("Microphone failed: \(error.localizedDescription)")
            scheduleReturnToIdle()
            return
        }
        state = .recording
        playSound("Tink")
        maxDurationTask = Task { [weak self, maxRecordingSeconds] in
            try? await Task.sleep(for: .seconds(maxRecordingSeconds))
            guard !Task.isCancelled else { return }
            self?.finishRecording()
        }
    }

    func hotkeyReleased() {
        guard case .recording = state else { return }
        finishRecording()
    }

    private func finishRecording() {
        maxDurationTask?.cancel()
        maxDurationTask = nil
        let samples = recorder.stop()
        playSound("Pop")

        guard samples.count >= minimumSampleCount else {
            state = .idle
            return
        }

        state = .transcribing
        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            do {
                var text = try await self.transcriber.transcribe(samples)
                for processor in self.processors {
                    text = processor.process(text)
                }
                guard !text.isEmpty else {
                    self.state = .idle
                    return
                }
                self.lastTranscript = text
                let result = self.inserter.insert(text)
                if result == .copiedToClipboard {
                    self.state = .error("Paste blocked — transcript is on your clipboard")
                    self.scheduleReturnToIdle()
                } else {
                    self.state = .idle
                }
            } catch {
                self.state = .error("Transcription failed: \(error.localizedDescription)")
                self.scheduleReturnToIdle()
            }
        }
    }

    private func scheduleReturnToIdle(after seconds: Double = 4) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, case .error = self.state else { return }
            self.state = .idle
        }
    }

    private func playSound(_ name: String) {
        guard settings.playSounds else { return }
        NSSound(named: name)?.play()
    }
}
