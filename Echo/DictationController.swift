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

    /// Set while a model switch is in flight; drives the Settings row spinner.
    @Published private(set) var pendingModelVariant: String?

    private let settings: SettingsStore
    private let recorder: AudioRecording
    private var transcriber: Transcribing
    private let makeTranscriber: (String) -> Transcribing
    private let inserter: TextInserting
    private let processors: [TextProcessor]
    private let captureConfiguration: CaptureConfiguration
    private let trimmer: any AudioTrimming
    private let transcripts: TranscriptStore?
    private let usage: UsageStore?
    private let dictionary: DictionaryStore?
    private let snippets: SnippetStore?
    private var hotkeyMonitor: HotkeyMonitoring
    private var overlay: OverlayController?
    private var maxDurationTask: Task<Void, Never>?
    private var micWakeTask: Task<Void, Never>?
    private let linkWaker = AudioLinkWaker()
    private lazy var waveformCoalescer = WaveformLevelCoalescer { [weak self] level in
        self?.audioLevel = level
    }
    private var recordingStartedAt: Date?
    private var cancellables: Set<AnyCancellable> = []

    /// Auto-stop cap so a stuck key can't record forever.
    private let maxRecordingSeconds: Double = 120
    /// How long to wait for first audio before nudging a dormant Bluetooth
    /// mic. Built-in mics deliver within ~100–200 ms, so this rarely fires
    /// spuriously — and the nudge is silent and harmless if it does.
    private let micWakeDelay: Duration = .milliseconds(300)

    /// Exposed so tests (and the UI, if ever needed) can await the in-flight transcription.
    private(set) var transcriptionTask: Task<Void, Never>?
    private var isFinishingRecording = false

    init(
        settings: SettingsStore = .shared,
        recorder: AudioRecording = AudioRecorder(),
        transcriber: Transcribing? = nil,
        transcriberFactory: ((String) -> Transcribing)? = nil,
        inserter: TextInserting = TextInserter(),
        processors: [TextProcessor] = [WhitespaceCleanupProcessor()],
        hotkeyMonitor: HotkeyMonitoring? = nil,
        transcripts: TranscriptStore? = nil,
        usage: UsageStore? = nil,
        dictionary: DictionaryStore? = nil,
        snippets: SnippetStore? = nil,
        captureConfiguration: CaptureConfiguration = .default,
        trimmer: (any AudioTrimming)? = nil,
        autostart: Bool = true
    ) {
        self.transcripts = transcripts
        self.usage = usage
        self.dictionary = dictionary
        self.snippets = snippets
        self.settings = settings
        self.recorder = recorder
        let factory = transcriberFactory ?? { TranscriptionService(modelVariant: $0) }
        self.makeTranscriber = factory
        self.transcriber = transcriber ?? factory(settings.modelVariant)
        self.inserter = inserter
        self.captureConfiguration = captureConfiguration
        self.trimmer = trimmer ?? VoiceActivityTrimmer(configuration: captureConfiguration)
        // Generic cleanup runs first. Dictionary replacement and snippet
        // expansion use store-owned compiled snapshots at dictation time so
        // mutations are visible without recompiling regexes per transcript.
        self.processors = processors
        self.hotkeyMonitor = hotkeyMonitor ?? HotkeyMonitor()

        self.hotkeyMonitor.onKeyDown = { [weak self] in self?.hotkeyPressed() }
        self.hotkeyMonitor.onKeyUp = { [weak self] in self?.hotkeyReleased() }

        let waveformCoalescer = self.waveformCoalescer
        self.recorder.onLevel = { level in
            waveformCoalescer.submit(level)
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
            try await prepareAndLoad()
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

    // MARK: - Model switching

    /// Switching is only safe when no dictation or model setup is in flight.
    var canSwitchModels: Bool {
        switch state {
        case .idle, .copyReady, .error: return true
        default: return false
        }
    }

    /// Downloads (if needed) and loads `variant`, persisting it only on
    /// success. On failure the previous model is reloaded — its files are
    /// local, so the revert works offline — and dictation keeps working.
    func switchModel(to variant: String) async {
        guard canSwitchModels else { return }
        let previousVariant = settings.modelVariant
        guard variant != previousVariant else { return }
        pendingModelVariant = variant
        defer { pendingModelVariant = nil }

        // Replace the old service first so its WhisperKit instance is
        // released before the new model loads (avoids 2x model memory).
        transcriber = makeTranscriber(variant)
        do {
            try await prepareAndLoad()
            settings.modelVariant = variant
            state = .idle
        } catch {
            transcriber = makeTranscriber(previousVariant)
            do {
                try await prepareAndLoad()
                state = .error("Couldn't switch model: \(error.localizedDescription)")
            } catch {
                state = .error("Model setup failed: \(error.localizedDescription)")
            }
            scheduleReturnToIdle()
        }
    }

    /// Shared model-setup sequence: drives the downloading/loading states
    /// that the sidebar, Home hero, and overlay already know how to render.
    private func prepareAndLoad() async throws {
        state = .downloadingModel(progress: 0)
        try await transcriber.prepare { [weak self] progress in
            Task { @MainActor in
                guard let self, case .downloadingModel = self.state else { return }
                self.state = .downloadingModel(progress: progress)
            }
        }
        state = .loadingModel
        try await transcriber.loadModel()
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
        waveformCoalescer.start()
        audioLevel = 0
        recordingStartedAt = Date()
        state = .recording
        // If the mic hasn't produced audio shortly after starting, nudge the
        // output side — a dormant Bluetooth link often needs outbound audio
        // before it will bring the microphone up at all.
        micWakeTask = Task { [weak self, micWakeDelay] in
            try? await Task.sleep(for: micWakeDelay)
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
        guard case .recording = state, !isFinishingRecording else { return }
        isFinishingRecording = true
        waveformCoalescer.stop()
        audioLevel = 0
        maxDurationTask?.cancel()
        maxDurationTask = nil
        micWakeTask?.cancel()
        micWakeTask = nil
        let heldFor = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        let releasedAt = Date()
        recordingStartedAt = nil

        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isFinishingRecording = false }
            let captured = await self.recorder.stop()
            await self.transcribeFinalizedCapture(
                captured,
                heldFor: heldFor,
                releasedAt: releasedAt
            )
        }
    }

    private func transcribeFinalizedCapture(
        _ captured: CapturedAudio,
        heldFor: TimeInterval,
        releasedAt: Date
    ) async {
        let modelVariant = settings.modelVariant
        guard micReady else {
            // A quick tap before any audio arrives is just an accidental press;
            // a sustained hold with nothing captured means the mic never woke up.
            if heldFor >= 0.8 {
                let fallback = TrimmedAudio.fallback(captured, reason: .noReliableSpeech)
                recordUsage(
                    words: 0,
                    captured: captured,
                    trimmed: fallback,
                    trimmingDuration: 0,
                    transcriptionDuration: nil,
                    releasedAt: releasedAt,
                    modelVariant: modelVariant,
                    outcome: .noAudio,
                    app: NSWorkspace.shared.frontmostApplication
                )
                state = .error("No audio from the microphone — try another input in the Echo menu")
                scheduleReturnToIdle()
            } else {
                state = .idle
            }
            return
        }

        guard captured.samples.count >= captureConfiguration.minimumRecordingSamples else {
            state = .idle
            return
        }

        state = .transcribing
        let trimmer = self.trimmer
        let trimmingStarted = Date()
        let trimmed = await Task.detached(priority: .userInitiated) {
            trimmer.trim(captured)
        }.value
        let trimmingDuration = Date().timeIntervalSince(trimmingStarted)
        guard trimmed.samples.count >= captureConfiguration.minimumRecordingSamples else {
            state = .idle
            return
        }
        let vocabulary = dictionary?.promptWords ?? []
        let frontApp = NSWorkspace.shared.frontmostApplication
        let transcriptionStarted = Date()

        do {
            var text = try await transcriber.transcribe(trimmed.samples, vocabulary: vocabulary)
            let transcriptionDuration = Date().timeIntervalSince(transcriptionStarted)
            let processingStarted = ContinuousClock.now
            for processor in processors {
                text = processor.process(text)
            }
            let replacementRules = dictionary?.compiledReplacementRules ?? []
            let snippetRules = snippets?.compiledRules ?? []
            text = await Task.detached(priority: .userInitiated) {
                var processed = ReplacementProcessor(rules: replacementRules).process(text)
                processed = SnippetProcessor(rules: snippetRules).process(processed)
                return processed
            }.value
            let processingDuration = processingStarted.duration(to: .now).timeInterval
            guard !text.isEmpty else {
                recordUsage(
                    words: 0,
                    captured: captured,
                    trimmed: trimmed,
                    trimmingDuration: trimmingDuration,
                    transcriptionDuration: transcriptionDuration,
                    processingDuration: processingDuration,
                    releasedAt: releasedAt,
                    modelVariant: modelVariant,
                    outcome: .emptyTranscript,
                    app: frontApp
                )
                state = .idle
                return
            }
            lastTranscript = text
            let insertionStarted = ContinuousClock.now
            if inserter.hasInsertionTarget {
                let result = inserter.insert(text)
                if result == .copiedToClipboard {
                    // Secure input appeared between the check and the paste.
                    offerCopy(of: text)
                } else {
                    state = .idle
                }
            } else {
                offerCopy(of: text)
            }
            let insertionDuration = insertionStarted.duration(to: .now).timeInterval
            if settings.saveHistory {
                transcripts?.add(text)
            }
            recordUsage(
                words: text.split(whereSeparator: \.isWhitespace).count,
                captured: captured,
                trimmed: trimmed,
                trimmingDuration: trimmingDuration,
                transcriptionDuration: transcriptionDuration,
                processingDuration: processingDuration,
                insertionDuration: insertionDuration,
                releasedAt: releasedAt,
                modelVariant: modelVariant,
                outcome: .success,
                app: frontApp
            )
        } catch {
            recordUsage(
                words: 0,
                captured: captured,
                trimmed: trimmed,
                trimmingDuration: trimmingDuration,
                transcriptionDuration: Date().timeIntervalSince(transcriptionStarted),
                releasedAt: releasedAt,
                modelVariant: modelVariant,
                outcome: .transcriptionFailure,
                app: frontApp
            )
            state = .error("Transcription failed: \(error.localizedDescription)")
            scheduleReturnToIdle()
        }
    }

    private func recordUsage(
        words: Int,
        captured: CapturedAudio,
        trimmed: TrimmedAudio,
        trimmingDuration: TimeInterval,
        transcriptionDuration: TimeInterval?,
        processingDuration: TimeInterval? = nil,
        insertionDuration: TimeInterval? = nil,
        releasedAt: Date,
        modelVariant: String,
        outcome: DictationOutcome,
        app: NSRunningApplication?
    ) {
        let totalLatency = Date().timeIntervalSince(releasedAt)
        usage?.record(
            words: words,
            duration: captured.duration,
            latency: totalLatency,
            appBundleID: app?.bundleIdentifier,
            appName: app?.localizedName,
            metrics: DictationOperationalMetrics(
                rawAudioDuration: captured.duration,
                selectedAudioDuration: Double(trimmed.samples.count) / captured.sampleRate,
                finalizationDuration: captured.finalizationDuration,
                trimmingDuration: trimmingDuration,
                transcriptionDuration: transcriptionDuration,
                processingDuration: processingDuration,
                insertionDuration: insertionDuration,
                historyPersistenceDuration: nil,
                totalLatency: totalLatency,
                trimmingApplied: trimmed.trimmingApplied,
                droppedBufferCount: captured.droppedBufferCount,
                finalizationTimedOut: captured.finalizationTimedOut,
                modelVariant: modelVariant,
                outcome: outcome
            )
        )
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

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
