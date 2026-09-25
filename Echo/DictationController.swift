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
    @Published private(set) var isCancelling = false
    @Published private(set) var deliveryNotice: String?
    @Published private(set) var activeMicrophoneName: String?
    @Published private(set) var provisionalText = ""
    var openMainWindow: (() -> Void)?

    /// Set while a model switch is in flight; drives the Settings row spinner.
    @Published private(set) var pendingModelVariant: String?

    private let settings: SettingsStore
    private let recorder: AudioRecording
    private var transcriber: Transcribing
    private var transcriberVariant: String
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
    private var recordingStartedAt: ContinuousClock.Instant?
    private var setupTask: Task<Void, Never>?
    private var setupID: UUID?
    private var expiryTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var permissionTask: Task<Void, Never>?
    private var modelReady = false
    private var checksPermissions = true
    private var activeSession: Session?
    private var lastSessionID: UUID?
    private var cancellationMessage: String?
    private var isTerminating = false
    private var modelLoadingDuration: TimeInterval?
    private var startupDuration: TimeInterval?

    private struct Session {
        let id: UUID
        let started: ContinuousClock.Instant
        var target: InsertionTarget?
        let app: NSRunningApplication?
        let modelVariant: String
        let request: TranscriptionRequest
        let replacements: [CompiledReplacementRule]
        let snippets: [CompiledSnippetRule]
        let keepOnClipboard: Bool
        let saveHistory: Bool
    }
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
        settings: SettingsStore? = nil,
        recorder: AudioRecording? = nil,
        transcriber: Transcribing? = nil,
        transcriberFactory: ((String) -> Transcribing)? = nil,
        inserter: TextInserting? = nil,
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
        let settings = settings ?? SettingsStore.shared
        let recorder = recorder ?? AudioRecorder()
        let inserter = inserter ?? TextInserter()
        self.transcripts = transcripts
        self.usage = usage
        self.dictionary = dictionary
        self.snippets = snippets
        self.settings = settings
        self.recorder = recorder
        let factory = transcriberFactory ?? { TranscriptionService(modelVariant: $0) }
        self.makeTranscriber = factory
        self.transcriber = transcriber ?? factory(settings.modelVariant)
        self.transcriberVariant = settings.modelVariant
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
        settings.$hotkey.removeDuplicates().sink { [weak self] hotkey in
            guard let self else { return }
            // A recording retains the physical binding that began it.
            if self.activeSession == nil { self.hotkeyMonitor.hotkey = hotkey }
        }.store(in: &cancellables)

        usage?.configure(enabled: settings.saveUsageStatistics, retentionDays: settings.usageRetentionDays)
        Publishers.CombineLatest(settings.$saveUsageStatistics, settings.$usageRetentionDays)
            .dropFirst().sink { [weak usage] enabled, days in
                usage?.configure(enabled: enabled, retentionDays: days)
            }.store(in: &cancellables)

        let isHostingTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        checksPermissions = autostart && !isHostingTests
        if autostart && !isHostingTests {
            let overlay = OverlayController()
            self.overlay = overlay
            overlay.onCopy = { [weak self] in self?.copyTranscript() }
            overlay.onCancel = { [weak self] in self?.cancelDictation() }
            overlay.onOpen = { [weak self] in self?.openMainWindow?() }
            Publishers.CombineLatest4($state, $audioLevel, $micReady, $copyConfirmed)
                .sink { state, level, micReady, copyConfirmed in
                    overlay.update(state: state, level: level, micReady: micReady, copyConfirmed: copyConfirmed)
                }
                .store(in: &cancellables)
            $isCancelling.sink { overlay.updateCancellation($0) }.store(in: &cancellables)
            Task { await start() }
            startPermissionMonitoring()
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.cancelDictation() }
                .store(in: &cancellables)
        }
    }

    var canCancel: Bool {
        activeSession != nil || isFinishingRecording || setupTask != nil
    }

    var canRetry: Bool {
        guard setupTask == nil, !isFinishingRecording, activeSession == nil else { return false }
        if case .error = state { return true }
        if case .needsPermissions = state { return true }
        return false
    }

    func start() async {
        await runSetup(variant: settings.modelVariant, forceRepair: false, allowRollback: false)
    }

    func retrySetup() async { await start() }

    func repairModel() async {
        guard canSwitchModels || canRetry else { return }
        await runSetup(variant: settings.modelVariant, forceRepair: true, allowRollback: false)
    }

    func activateForTesting() {
        checksPermissions = false
        modelReady = true
        state = .idle
    }

    var canSwitchModels: Bool {
        guard setupTask == nil, !isFinishingRecording, activeSession == nil, !isCancelling else { return false }
        switch state {
        case .idle, .copyReady, .error: return true
        default: return false
        }
    }

    func switchModel(to variant: String) async {
        guard canSwitchModels, variant != settings.modelVariant else { return }
        await runSetup(variant: variant, forceRepair: false, allowRollback: true)
    }

    private func runSetup(variant: String, forceRepair: Bool, allowRollback: Bool) async {
        guard setupTask == nil, !isFinishingRecording, activeSession == nil else { return }
        expiryTask?.cancel()
        let id = UUID()
        let previousVariant = settings.modelVariant
        let setupStarted = ContinuousClock.now
        setupID = id
        modelReady = false
        pendingModelVariant = variant
        hotkeyMonitor.stop()
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.setupID == id {
                    self.setupID = nil
                    self.setupTask = nil
                    self.pendingModelVariant = nil
                    self.isCancelling = false
                }
            }
            do {
                if self.checksPermissions { try await self.waitForPermissions() }
                try Task.checkCancellation()
                if variant != self.transcriberVariant || forceRepair {
                    self.transcriber = self.makeTranscriber(variant)
                    self.transcriberVariant = variant
                }
                try await self.prepareAndLoad(id: id, forceRepair: forceRepair)
                try Task.checkCancellation()
                guard self.setupID == id else { return }
                self.settings.modelVariant = variant
                self.startupDuration = setupStarted.duration(to: .now).timeInterval
                self.modelReady = true
                self.armReadyState()
            } catch is CancellationError {
                self.state = .error("Model setup cancelled. Retry when ready.")
            } catch {
                let failure = error.localizedDescription
                if allowRollback, !Task.isCancelled {
                    self.transcriber = self.makeTranscriber(previousVariant)
                    self.transcriberVariant = previousVariant
                    do {
                        try await self.prepareAndLoad(id: id, forceRepair: false)
                        try Task.checkCancellation()
                        self.modelReady = true
                        self.armReadyState()
                        self.state = .error("Couldn't switch model: \(failure)")
                        self.scheduleReturnToIdle()
                    } catch {
                        self.state = .error("Model recovery failed: \(error.localizedDescription). Retry or repair the model in Settings.")
                    }
                } else {
                    self.state = .error("Model setup failed: \(failure). Retry or repair the model in Settings.")
                }
            }
        }
        setupTask = task
        await task.value
    }

    private func prepareAndLoad(id: UUID, forceRepair: Bool) async throws {
        state = .downloadingModel(progress: 0)
        try await transcriber.prepare(forceRepair: forceRepair) { [weak self] progress in
            Task { @MainActor in
                guard let self, self.setupID == id, !self.isCancelling,
                      case .downloadingModel = self.state else { return }
                self.state = .downloadingModel(progress: min(1, max(0, progress)))
            }
        }
        try Task.checkCancellation()
        state = .loadingModel
        let loadingStarted = ContinuousClock.now
        try await transcriber.loadModel()
        modelLoadingDuration = loadingStarted.duration(to: .now).timeInterval
    }

    private func armReadyState() {
        guard modelReady, !isTerminating else { return }
        if checksPermissions && !(Permissions.microphoneGranted && Permissions.accessibilityGranted) {
            state = .needsPermissions(microphone: Permissions.microphoneGranted,
                                      accessibility: Permissions.accessibilityGranted)
            return
        }
        hotkeyMonitor.hotkey = settings.hotkey
        hotkeyMonitor.start()
        state = .idle
    }

    private func waitForPermissions() async throws {
        _ = await Permissions.requestMicrophone()
        if !Permissions.accessibilityGranted { Permissions.promptForAccessibility() }
        while !(Permissions.microphoneGranted && Permissions.accessibilityGranted) {
            try Task.checkCancellation()
            state = .needsPermissions(microphone: Permissions.microphoneGranted,
                                      accessibility: Permissions.accessibilityGranted)
            try await Task.sleep(for: .seconds(1))
        }
    }

    private func startPermissionMonitoring() {
        permissionTask?.cancel()
        guard checksPermissions else { return }
        permissionTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                self?.refreshPermissions()
            }
        }
    }

    private func refreshPermissions() {
        guard checksPermissions, !isTerminating, setupTask == nil else { return }
        if !(Permissions.microphoneGranted && Permissions.accessibilityGranted) {
            if activeSession != nil { cancelDictation() }
            hotkeyMonitor.stop()
            if !isFinishingRecording {
                state = .needsPermissions(microphone: Permissions.microphoneGranted,
                                          accessibility: Permissions.accessibilityGranted)
            }
        } else if case .needsPermissions = state {
            if modelReady { armReadyState() }
            else { Task { await start() } }
        }
    }

    func cancelDictation() {
        expiryTask?.cancel()
        if let setupTask {
            isCancelling = true
            setupTask.cancel()
            deliveryNotice = "Cancelling model setup…"
            return
        }
        guard activeSession != nil || isFinishingRecording else { return }
        cancellationMessage = cancellationMessage ?? "Dictation cancelled"
        isCancelling = true
        let cancelledSession = activeSession
        activeSession = nil
        maxDurationTask?.cancel()
        micWakeTask?.cancel()
        waveformCoalescer.stop()
        audioLevel = 0
        provisionalText = ""
        if isFinishingRecording {
            transcriptionTask?.cancel()
        } else {
            isFinishingRecording = true
            state = .transcribing
            transcriptionTask = Task { [weak self] in
                guard let self else { return }
                let captured = await self.recorder.stop()
                if let session = cancelledSession {
                    self.recordCancellation(captured, session: session, releasedAt: .now)
                }
                self.completeOperation()
            }
        }
        deliveryNotice = "Cancelling… waiting for the current operation to stop."
    }

    func prepareForTermination() {
        isTerminating = true
        cancelDictation()
        permissionTask?.cancel()
        expiryTask?.cancel()
        timeoutTask?.cancel()
        hotkeyMonitor.stop()
    }

    func resumeAfterCancelledTermination() {
        isTerminating = false
        startPermissionMonitoring()
        if modelReady && !isFinishingRecording && setupTask == nil { armReadyState() }
    }

    func drainOperations() async {
        await setupTask?.value
        await transcriptionTask?.value
        await inserter.flushPendingRestoration()
    }

    private func completeOperation() {
        timeoutTask?.cancel()
        timeoutTask = nil
        isFinishingRecording = false
        activeSession = nil
        transcriptionTask = nil
        recorder.onCaptureReady = nil
        recorder.onCaptureReadyForGeneration = nil
        recorder.onInterruption = nil
        hotkeyMonitor.hotkey = settings.hotkey
        if isCancelling {
            isCancelling = false
            let message = cancellationMessage ?? "Dictation cancelled"
            cancellationMessage = nil
            deliveryNotice = message
            if modelReady { armReadyState() }
            else { state = .error("Speech model unavailable. Retry setup.") }
        }
    }

    // MARK: - Recording lifecycle

    func hotkeyPressed() {
        guard !isTerminating, modelReady, setupTask == nil, !isFinishingRecording, !isCancelling else { return }
        switch state {
        case .idle, .copyReady: break
        default: return
        }
        if checksPermissions && !(Permissions.microphoneGranted && Permissions.accessibilityGranted) {
            refreshPermissions()
            return
        }
        expiryTask?.cancel()
        deliveryNotice = nil
        activeMicrophoneName = nil
        provisionalText = ""
        micReady = false
        copyConfirmed = false
        cancellationMessage = nil
        let id = UUID()
        let started = ContinuousClock.now
        let language = WhisperModelCatalog.supportsMultilingual(settings.modelVariant)
            ? (settings.transcriptionLanguage == "auto" ? nil : settings.transcriptionLanguage)
            : "en"
        var session = Session(
            id: id, started: started, target: nil,
            app: NSWorkspace.shared.frontmostApplication, modelVariant: settings.modelVariant,
            request: TranscriptionRequest(vocabulary: dictionary?.promptWords ?? [],
                                          language: language,
                                          promptTokenBudget: settings.vocabularyTokenBudget,
                                          temperatureFallbackCount: settings.decodingFallbackCount),
            replacements: dictionary?.compiledReplacementRules ?? [],
            snippets: settings.expandSnippets ? (snippets?.compiledRules ?? []) : [],
            keepOnClipboard: settings.copyTranscriptToClipboard, saveHistory: settings.saveHistory)
        activeSession = session
        recorder.onCaptureReady = { [weak self] in
            Task { @MainActor in
                guard let self, self.activeSession?.id == id,
                      self.recorder.captureGeneration == nil,
                      case .recording = self.state else { return }
                self.micReady = true
            }
        }
        recorder.onCaptureReadyForGeneration = { [weak self] generation in
            Task { @MainActor in
                guard let self, self.activeSession?.id == id,
                      self.recorder.captureGeneration == generation,
                      case .recording = self.state else { return }
                self.micReady = true
            }
        }
        recorder.onInterruption = { [weak self] generation, reason in
            Task { @MainActor in
                guard let self, self.activeSession?.id == id,
                      self.recorder.captureGeneration == generation else { return }
                self.deliveryNotice = reason
                self.finishRecording()
            }
        }
        do { try recorder.start(deviceUID: settings.inputDeviceUID) }
        catch {
            activeSession = nil
            state = .error("Microphone failed: \(error.localizedDescription)")
            scheduleReturnToIdle()
            return
        }
        // Begin capturing before synchronous AX calls: a slow destination must
        // not consume the first spoken word. Retain the key-down application;
        // any app change while starting audio forces the copy fallback.
        let target = inserter.captureTarget()
        if target?.processID == session.app?.processIdentifier {
            session.target = target
        }
        activeSession = session
        waveformCoalescer.start()
        audioLevel = 0
        recordingStartedAt = started
        state = .recording
        micWakeTask = Task { [weak self, micWakeDelay] in
            do { try await Task.sleep(for: micWakeDelay) } catch { return }
            guard let self, self.activeSession?.id == id,
                  case .recording = self.state, !self.micReady,
                  self.recorder.needsBluetoothWake else { return }
            self.linkWaker.wake()
        }
        maxDurationTask = Task { [weak self, maxRecordingSeconds] in
            do { try await Task.sleep(for: .seconds(maxRecordingSeconds)) } catch { return }
            guard self?.activeSession?.id == id else { return }
            self?.finishRecording()
        }
    }

    func hotkeyReleased() {
        guard case .recording = state else { return }
        finishRecording()
    }

    private func finishRecording() {
        guard case .recording = state, !isFinishingRecording, let session = activeSession else { return }
        isFinishingRecording = true
        waveformCoalescer.stop()
        audioLevel = 0
        maxDurationTask?.cancel()
        maxDurationTask = nil
        micWakeTask?.cancel()
        micWakeTask = nil
        let heldFor = recordingStartedAt.map { $0.duration(to: .now).timeInterval } ?? 0
        let releasedAt = ContinuousClock.now
        recordingStartedAt = nil

        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            defer { self.completeOperation() }
            let captured = await self.recorder.stop()
            guard self.activeSession?.id == session.id, !Task.isCancelled else {
                self.recordCancellation(captured, session: session, releasedAt: releasedAt)
                return
            }
            await self.transcribeFinalizedCapture(captured, heldFor: heldFor,
                                                 releasedAt: releasedAt, session: session)
            if self.activeSession?.id != session.id || Task.isCancelled {
                self.recordCancellation(captured, session: session, releasedAt: releasedAt)
            }
        }
    }

    private func recordCancellation(_ captured: CapturedAudio, session: Session, releasedAt: ContinuousClock.Instant) {
        recordUsage(words: 0, captured: captured,
                    trimmed: .fallback(captured, reason: .noReliableSpeech),
                    trimmingDuration: 0, transcriptionDuration: nil, releasedAt: releasedAt,
                    modelVariant: session.modelVariant, outcome: .cancelled, app: session.app,
                    sessionID: session.id)
    }

    private func transcribeFinalizedCapture(
        _ captured: CapturedAudio,
        heldFor: TimeInterval,
        releasedAt: ContinuousClock.Instant,
        session: Session
    ) async {
        let modelVariant = session.modelVariant
        activeMicrophoneName = captured.actualDeviceName
        if captured.usedFallbackDevice { deliveryNotice = "Using the system microphone because the selected input is unavailable." }
        if captured.interrupted,
           !captured.transportReady || captured.samples.count < captureConfiguration.minimumRecordingSamples {
            recordUsage(words: 0, captured: captured,
                        trimmed: .fallback(captured, reason: .noReliableSpeech),
                        trimmingDuration: 0, transcriptionDuration: nil, releasedAt: releasedAt,
                        modelVariant: modelVariant, outcome: .noAudio, app: session.app, sessionID: session.id)
            state = .error(captured.interruptionReason ?? "Microphone interrupted. Check the input in Settings and record again.")
            scheduleReturnToIdle()
            return
        }
        guard captured.transportReady else {
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
                    app: session.app,
                    sessionID: session.id
                )
                state = .error("No audio from the microphone — choose another input in Settings")
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
        let trimmingStarted = ContinuousClock.now
        let trimmed = await Task.detached(priority: .userInitiated) {
            trimmer.trim(captured)
        }.value
        let trimmingDuration = trimmingStarted.duration(to: .now).timeInterval
        guard activeSession?.id == session.id, !Task.isCancelled else { return }
        guard trimmed.samples.count >= captureConfiguration.minimumRecordingSamples else {
            state = .idle
            return
        }
        let frontApp = session.app
        let transcriptionStarted = ContinuousClock.now
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(30, captured.duration * 2))) } catch { return }
            guard let self, self.activeSession?.id == session.id else { return }
            self.cancellationMessage = "Transcription took too long and was cancelled. Try a shorter recording."
            self.cancelDictation()
        }

        do {
            let output = try await transcriber.transcribe(trimmed.samples, request: session.request)
            guard activeSession?.id == session.id, !Task.isCancelled else { return }
            var text = output.text
            let recognizedWords = TextWordCounter.count(text, language: output.language)
            let transcriptionDuration = transcriptionStarted.duration(to: .now).timeInterval
            let processingStarted = ContinuousClock.now
            for processor in processors {
                text = processor.process(text)
            }
            let replacementRules = session.replacements
            let snippetRules = session.snippets
            text = await Task.detached(priority: .userInitiated) {
                var processed = ReplacementProcessor(rules: replacementRules).process(text)
                processed = SnippetProcessor(rules: snippetRules).process(processed)
                return processed
            }.value
            let processingDuration = processingStarted.duration(to: .now).timeInterval
            guard activeSession?.id == session.id, !Task.isCancelled else { return }
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
                    outcome: output.diagnostics.isDigitalSilence ? .noSpeech : .emptyTranscript,
                    app: frontApp,
                    sessionID: session.id,
                    output: output,
                    request: session.request
                )
                state = .idle
                return
            }
            lastTranscript = text
            lastSessionID = session.id
            let insertionStarted = ContinuousClock.now
            let keepOnClipboard = session.keepOnClipboard
            var outcome: DictationOutcome = .pasteDispatched
            if output.needsReview || captured.interrupted || !inserter.targetMatches(session.target) {
                deliveryNotice = captured.interruptionReason ?? (output.needsReview
                    ? "Review this transcript before copying."
                    : "The destination changed. Your transcript is ready to copy.")
                offerCopy(of: text)
                outcome = .awaitingCopy
            } else if inserter.hasInsertionTarget {
                switch inserter.insert(text, keepOnClipboard: keepOnClipboard, target: session.target) {
                case .pasted: state = .idle
                case .copiedToClipboard:
                    if keepOnClipboard {
                        deliveryNotice = "Transcript copied to clipboard."
                        state = .idle
                        showCopiedConfirmation()
                        outcome = .copied
                    } else {
                        offerCopy(of: text)
                        outcome = .awaitingCopy
                    }
                case .copyRequired, .failed:
                    deliveryNotice = "Automatic paste was unavailable. Your transcript is ready to copy."
                    offerCopy(of: text)
                    outcome = .awaitingCopy
                }
            } else if keepOnClipboard {
                if inserter.copyWithResult(text) {
                    deliveryNotice = "No text field available. Transcript copied to clipboard."
                    state = .idle
                    showCopiedConfirmation()
                    outcome = .copied
                } else {
                    deliveryNotice = "Could not write to the clipboard. Your transcript is ready to copy again."
                    offerCopy(of: text)
                    outcome = .awaitingCopy
                }
            } else {
                offerCopy(of: text)
                outcome = .awaitingCopy
            }
            let insertionDuration = insertionStarted.duration(to: .now).timeInterval
            if session.saveHistory {
                transcripts?.add(text)
            }
            recordUsage(
                words: recognizedWords,
                captured: captured,
                trimmed: trimmed,
                trimmingDuration: trimmingDuration,
                transcriptionDuration: transcriptionDuration,
                processingDuration: processingDuration,
                insertionDuration: insertionDuration,
                releasedAt: releasedAt,
                modelVariant: modelVariant,
                outcome: outcome,
                app: frontApp,
                sessionID: session.id,
                expandedWords: TextWordCounter.count(text, language: output.language),
                output: output,
                request: session.request
            )
        } catch {
            guard activeSession?.id == session.id, !Task.isCancelled else { return }
            recordUsage(
                words: 0,
                captured: captured,
                trimmed: trimmed,
                trimmingDuration: trimmingDuration,
                transcriptionDuration: transcriptionStarted.duration(to: .now).timeInterval,
                releasedAt: releasedAt,
                modelVariant: modelVariant,
                outcome: .transcriptionFailure,
                app: frontApp,
                sessionID: session.id,
                request: session.request
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
        releasedAt: ContinuousClock.Instant,
        modelVariant: String,
        outcome: DictationOutcome,
        app: NSRunningApplication?,
        sessionID: UUID? = nil,
        expandedWords: Int? = nil,
        output: TranscriptionOutput? = nil,
        request: TranscriptionRequest? = nil
    ) {
        let totalLatency = releasedAt.duration(to: .now).timeInterval
        var metrics = DictationOperationalMetrics(
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
        metrics.transportReadyDuration = captured.readyDuration
        metrics.captureTailDuration = captured.tailDuration
        metrics.inputGapCount = captured.inputGapCount
        metrics.captureInterrupted = captured.interrupted
        metrics.startupDuration = startupDuration
        metrics.modelLoadingDuration = modelLoadingDuration
        metrics.promptConstructionDuration = output?.diagnostics.promptDuration
        metrics.featureExtractionDuration = output?.diagnostics.featureDuration
        metrics.encoderDuration = output?.diagnostics.encoderDuration
        metrics.decoderDuration = output?.diagnostics.decoderDuration
        metrics.trimReason = trimmed.fallbackReason?.rawValue ?? "trimmed"
        metrics.language = output?.language ?? request?.language
        metrics.vocabularyTokenBudget = request?.promptTokenBudget
        metrics.decodingFallbackCount = request?.temperatureFallbackCount
        metrics.appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        metrics.buildVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        metrics.dependencyVersion = "0.18.0"
        usage?.record(
            words: words,
            duration: captured.duration,
            latency: totalLatency,
            appBundleID: app?.bundleIdentifier,
            appName: app?.localizedName,
            metrics: metrics,
            expandedWords: expandedWords,
            sessionID: sessionID
        )
    }

    // MARK: - Copy fallback

    private func offerCopy(of text: String) {
        expiryTask?.cancel()
        copyConfirmed = false
        state = .copyReady(text)
        // Keep the result until copied or superseded; losing a ten-second offer
        // made results unrecoverable when history and clipboard retention were off.
    }

    func copyTranscript() {
        let text: String
        if case .copyReady(let value) = state { text = value }
        else { text = lastTranscript }
        guard !text.isEmpty else { return }
        guard inserter.copyWithResult(text) else {
            copyConfirmed = false
            deliveryNotice = "Could not write to the clipboard. Try Copy again."
            return
        }
        if let id = lastSessionID { usage?.updateOutcome(sessionID: id, outcome: .copied) }
        deliveryNotice = "Transcript copied to clipboard."
        showCopiedConfirmation()
    }

    private func showCopiedConfirmation() {
        copyConfirmed = true
        expiryTask?.cancel()
        let id = lastSessionID
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1.2)) } catch { return }
            guard let self, self.lastSessionID == id, self.activeSession == nil else { return }
            if case .copyReady = self.state { self.state = .idle }
            self.copyConfirmed = false
        }
    }

    private func scheduleReturnToIdle(after seconds: Double = 4) {
        expiryTask?.cancel()
        let errorState = state
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard let self, self.state == errorState, self.modelReady,
                  self.activeSession == nil, self.setupTask == nil else { return }
            self.armReadyState()
        }
    }

}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
