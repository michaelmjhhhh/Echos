import SwiftUI

struct HomeView: View {
    @Binding var section: MainSection

    @EnvironmentObject private var controller: DictationController
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var transcripts: TranscriptStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if case .needsPermissions(let mic, let ax) = controller.state {
                    PermissionsBanner(microphone: mic, accessibility: ax)
                }

                hero

                HStack(spacing: 16) {
                    infoCard(eyebrow: "Microphone", value: microphoneName)
                    infoCard(eyebrow: "Model", value: modelDisplayName)
                    todayCard
                }

                recentSection
            }
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
            .padding(24)
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 16) {
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
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .echoCard(padding: 24)
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

    private var microphoneName: String {
        guard let uid = settings.inputDeviceUID else { return "System Default" }
        return AudioInputDevices.all().first { $0.uid == uid }?.name ?? "System Default"
    }

    private var modelDisplayName: String {
        settings.modelVariant.contains("distil") ? "Whisper Distil Large v3" : settings.modelVariant
    }

    private func infoCard(eyebrow: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
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
        VStack(alignment: .leading, spacing: 8) {
            EyebrowText(text: "Today")
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("\(transcripts.todayWordCount)")
                    .font(.echoMono(15, medium: true))
                    .foregroundStyle(Color.echoText)
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
        VStack(alignment: .leading, spacing: 12) {
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
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .font(.echo(12, .medium))
                        .foregroundStyle(Color.echoSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            if transcripts.entries.isEmpty {
                HStack(spacing: 6) {
                    Text("Nothing here yet — hold")
                    KeycapView(label: settings.hotkey.label)
                    Text("and your words land here.")
                }
                .font(.echo(13))
                .foregroundStyle(Color.echoSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .echoCard()
            } else {
                VStack(spacing: 8) {
                    ForEach(transcripts.entries.prefix(3)) { entry in
                        TranscriptRow(entry: entry, compact: true)
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
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.echoWarning)
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
            }
            if !accessibility {
                Button("Open Accessibility Settings") { Permissions.openAccessibilitySettings() }
            }
        }
        .echoCard()
    }
}
