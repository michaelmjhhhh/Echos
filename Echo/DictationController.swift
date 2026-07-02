import AppKit
import Combine

@MainActor
final class DictationController: ObservableObject {
    @Published private(set) var state: DictationState = .launching
    @Published private(set) var lastTranscript: String = ""
    /// Live microphone level (0...1) while recording, drives the overlay waveform.
    @Published private(set) var audioLevel: Float = 0
    /// False until real audio arrives for the current recording — Bluetooth mics
    /// take seconds to wake, and the overlay shows "Starting mic…" until then.
    @Published private(set) var micReady = false
    /// Briefly true after the user clicks Copy on the pill.
    @Published private(set) var copyConfirmed = false

    private let settings: SettingsStore
    private let recorder: AudioRecording
    private let transcriber: Transcribing
    private let inserter: TextInserting
    private let processors: [TextProcessor]
    private let transcripts: TranscriptStore?
    private let usage: UsageStore?
    private var hotkeyMonitor: HotkeyMonitoring
    private var overlay: OverlayController?
    private var maxDurationTask: Task<Void, Never>?
    private var micWakeTask: Task<Void, Never>?
    private let linkWaker = AudioLinkWaker()
    private var recordingStartedAt: Date?
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
        transcripts: TranscriptStore? = nil,
        usage: UsageStore? = nil,
        autostart: Bool = true
    ) {
        self.transcripts = transcripts
        self.usage = usage
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
        self.recorder.onCaptureReady = { [weak self] in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.micReady = true }
            } else {
                Task { @MainActor in self?.micReady = true }
            }
        }

        settings.$hotkey
            .removeDuplicates()
            .sink { [weak self] hotkey in self?.hotkeyMonitor.hotkey = hotkey }
            .store(in: &cancellables)

        let isHostingTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        #if DEBUG
        // Temporary diagnostic: exercise the insertion-target check on a timer
        // so the decision can be observed via `log show` without dictating.
        if autostart && !isHostingTests && ProcessInfo.processInfo.environment["ECHO_PROBE_TARGET"] != nil {
            Task { [inserter] in
                while !Task.isCancelled {
                    _ = inserter.hasInsertionTarget
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
        #endif
        if autostart && !isHostingTests {
            let overlay = OverlayController()
            self.overlay = overlay
            overlay.onCopy = { [weak self] in self?.copyTranscript() }
            Publishers.CombineLatest4($state, $audioLevel, $micReady, $copyConfirmed)
                .sink { state, level, micReady, copyConfirmed in
                    overlay.update(state: state, level: level, micReady: micReady, copyConfirmed: copyConfirmed)
                }
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
        switch state {
        case .idle: break
        case .copyReady: state = .idle // a new dictation supersedes the offer
        default: return
        }
        micReady = false
        copyConfirmed = false
        do {
            try recorder.start(deviceUID: settings.inputDeviceUID)
        } catch {
            state = .error("Microphone failed: \(error.localizedDescription)")
            scheduleReturnToIdle()
            return
        }
        recordingStartedAt = Date()
        state = .recording
        // If the mic hasn't produced audio shortly after starting, nudge the
        // output side — a dormant Bluetooth link often needs outbound audio
        // before it will bring the microphone up at all.
        micWakeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self,
                  case .recording = self.state, !self.micReady else { return }
            self.linkWaker.wake()
        }
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
        micWakeTask?.cancel()
        micWakeTask = nil
        let samples = recorder.stop()
        let heldFor = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        recordingStartedAt = nil

        guard micReady else {
            // A quick tap before any audio arrives is just an accidental press;
            // a sustained hold with nothing captured means the mic never woke up.
            if heldFor >= 0.8 {
                state = .error("No audio from the microphone — try another input in the Echo menu")
                scheduleReturnToIdle()
            } else {
                state = .idle
            }
            return
        }

        guard samples.count >= minimumSampleCount else {
            state = .idle
            return
        }

        state = .transcribing
        let duration = Double(samples.count) / AudioRecorder.sampleRate
        let releasedAt = Date()
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
                if self.settings.saveHistory {
                    self.transcripts?.add(text)
                }

                let frontApp = NSWorkspace.shared.frontmostApplication
                let recordUsage = {
                    self.usage?.record(
                        words: text.split(whereSeparator: \.isWhitespace).count,
                        duration: duration,
                        latency: Date().timeIntervalSince(releasedAt),
                        appBundleID: frontApp?.bundleIdentifier,
                        appName: frontApp?.localizedName
                    )
                }

                if self.inserter.hasInsertionTarget {
                    let result = self.inserter.insert(text)
                    recordUsage()
                    if result == .copiedToClipboard {
                        // Secure input appeared between the check and the paste.
                        self.offerCopy(of: text)
                    } else {
                        self.state = .idle
                    }
                } else {
                    recordUsage()
                    self.offerCopy(of: text)
                }
            } catch {
                self.state = .error("Transcription failed: \(error.localizedDescription)")
                self.scheduleReturnToIdle()
            }
        }
    }

    // MARK: - Copy fallback

    private func offerCopy(of text: String) {
        copyConfirmed = false
        state = .copyReady(text)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, case .copyReady(text) = self.state else { return }
            self.state = .idle
        }
    }

    /// Called when the user clicks Copy on the floating pill.
    func copyTranscript() {
        guard case .copyReady(let text) = state else { return }
        inserter.copyToClipboard(text)
        copyConfirmed = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard let self, case .copyReady = self.state else { return }
            self.state = .idle
            self.copyConfirmed = false
        }
    }

    private func scheduleReturnToIdle(after seconds: Double = 4) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, case .error = self.state else { return }
            self.state = .idle
        }
    }

}
