import SwiftUI

struct HomeView: View {
    @Binding var section: MainSection

    @EnvironmentObject private var controller: DictationController
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var transcripts: TranscriptStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var microphoneName = "System Default"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                if case .needsPermissions(let mic, let ax) = controller.state {
                    PermissionsBanner(microphone: mic, accessibility: ax)
                }

                hero
                    .echoStagger(0, reduceMotion: reduceMotion)

                HStack(spacing: Spacing.m) {
                    infoCard(eyebrow: "Microphone", value: microphoneName)
                    infoCard(eyebrow: "Model", value: modelDisplayName)
                    todayCard
                }
                .echoStagger(1, reduceMotion: reduceMotion)

                recentSection
                    .echoStagger(2, reduceMotion: reduceMotion)
            }
            .echoContentColumn()
        }
        // Same rule as the sidebar: HAL queries only on selection change,
        // never per render — this view re-renders at waveform frequency.
        .onChange(of: settings.inputDeviceUID, initial: true) { _, uid in
            microphoneName = MainWindowView.resolveMicrophoneName(uid: uid)
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: Spacing.m) {
            WaveformRibbon(level: controller.audioLevel, isLive: isLive)

            Text(heroStatus)
                .font(.echoDisplay(24))
                .tracking(-0.4)
                .foregroundStyle(Color.echoText)
                .contentTransition(.opacity)

            HStack(spacing: 6) {
                Text("Hold")
                    .foregroundStyle(Color.echoSecondary)
                KeycapView(label: settings.hotkey.label)
                Text("in any app — release to insert your words at the cursor.")
                    .foregroundStyle(Color.echoSecondary)
            }
            .font(.echo(12))
            .padding(.top, Spacing.xs)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.xl)
        .echoCard(padding: Spacing.l)
        .animation(reduceMotion ? nil : Motion.spring, value: controller.state)
    }

    private var isLive: Bool {
        if case .recording = controller.state { return controller.micReady }
        return false
    }

    private var heroStatus: String {
        switch controller.state {
        case .launching: return "Warming up…"
        case .needsPermissions: return "Almost there — grant the permissions above"
        case .downloadingModel(let progress): return "Downloading speech model… \(Int(progress * 100))%"
        case .loadingModel: return "Loading speech model…"
        case .idle: return "Ready when you are"
        case .recording: return controller.micReady ? "Listening…" : "Starting mic…"
        case .transcribing: return "Transcribing…"
        case .copyReady: return "No text field — copy from the pill below"
        case .error(let message): return message
        }
    }

    // MARK: - Info cards

    private var modelDisplayName: String {
        WhisperModelCatalog.displayName(for: settings.modelVariant)
    }

    private func infoCard(eyebrow: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            EyebrowText(text: eyebrow)
            Text(value)
                .font(.echo(15, .medium))
                .foregroundStyle(Color.echoText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .echoCard()
    }

    private var todayCard: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            EyebrowText(text: "Today")
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("\(transcripts.todayWordCount)")
                    .font(.echoMono(15, medium: true))
                    .foregroundStyle(Color.echoText)
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : Motion.spring, value: transcripts.todayWordCount)
                Text("words · \(transcripts.todayEntries.count) dictations")
                    .font(.echo(12))
                    .foregroundStyle(Color.echoSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .echoCard()
    }

    // MARK: - Recent

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack {
                EyebrowText(text: "Recent")
                Spacer()
                if !transcripts.entries.isEmpty {
                    Button {
                        withAnimation(reduceMotion ? nil : Motion.spring) { section = .history }
                    } label: {
                        HStack(spacing: 3) {
                            Text("View all")
                            Image(systemName: "arrow.right")
                                .font(.system(size: IconSize.caption, weight: .semibold))
                        }
                        .font(.echo(12, .medium))
                        .foregroundStyle(Color.echoSecondary)
                    }
                    .buttonStyle(EchoPressButtonStyle())
                    .accessibilityLabel("View all transcripts")
                    .help("Open History (⌘3)")
                }
            }

            if transcripts.entries.isEmpty {
                EchoEmptyState {
                    HStack(spacing: 6) {
                        Text("Nothing here yet — hold")
                        KeycapView(label: settings.hotkey.label)
                        Text("and your words land here.")
                    }
                }
                .padding(.vertical, Spacing.l)
                .echoCard()
            } else {
                VStack(spacing: Spacing.xs) {
                    ForEach(Array(transcripts.entries.prefix(3).enumerated()), id: \.element.id) { index, entry in
                        TranscriptRow(entry: entry, compact: true)
                            .echoStagger(index, reduceMotion: reduceMotion)
                    }
                }
            }
        }
    }
}

private struct PermissionsBanner: View {
    let microphone: Bool
    let accessibility: Bool

    var body: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.echoWarning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Echo needs permission to work")
                    .font(.echo(13, .semibold))
                    .foregroundStyle(Color.echoText)
                Text("Dictation stays paused until access is granted.")
                    .font(.echo(12))
                    .foregroundStyle(Color.echoSecondary)
            }
            Spacer()
            if !microphone {
                Button("Open Microphone Settings") { Permissions.openMicrophoneSettings() }
                    .buttonStyle(EchoPrimaryButtonStyle())
            }
            if !accessibility {
                Button("Open Accessibility Settings") { Permissions.openAccessibilitySettings() }
                    .buttonStyle(EchoPrimaryButtonStyle())
            }
        }
        .echoCard()
    }
}
