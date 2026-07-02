import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var controller: DictationController
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var transcripts: TranscriptStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if case .needsPermissions(let mic, let ax) = controller.state {
                PermissionsBanner(microphone: mic, accessibility: ax)
            }

            hero

            HStack(spacing: 16) {
                infoCard(
                    eyebrow: "Microphone",
                    value: microphoneName,
                    symbol: "mic"
                )
                infoCard(
                    eyebrow: "Model",
                    value: modelDisplayName,
                    symbol: "cpu"
                )
                todayCard
            }

            Spacer()
        }
        .padding(24)
    }

    private var hero: some View {
        VStack(spacing: 18) {
            WaveformRibbon(level: controller.audioLevel, isLive: isLive)

            Text(heroStatus)
                .font(.echoDisplay(19))
                .tracking(-0.3)
                .foregroundStyle(Color.echoText)

            HStack(spacing: 6) {
                Text("Hold")
                    .foregroundStyle(Color.echoSecondary)
                KeycapView(label: settings.hotkey.label)
                Text("in any app — release to insert your words at the cursor.")
                    .foregroundStyle(Color.echoSecondary)
            }
            .font(.echo(12))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .echoCard(padding: 24)
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
        case .error(let message): return message
        }
    }

    private var microphoneName: String {
        guard let uid = settings.inputDeviceUID else { return "System Default" }
        return AudioInputDevices.all().first { $0.uid == uid }?.name ?? "System Default"
    }

    private var modelDisplayName: String {
        // "distil-whisper_distil-large-v3_594MB" → "Distil Large v3"
        settings.modelVariant.contains("distil") ? "Whisper Distil Large v3" : settings.modelVariant
    }

    private func infoCard(eyebrow: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.echoSecondary)
                EyebrowText(text: eyebrow)
            }
            Text(value)
                .font(.echo(13, .medium))
                .foregroundStyle(Color.echoText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .echoCard()
    }

    private var todayCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.echoSecondary)
                EyebrowText(text: "Today")
            }
            HStack(spacing: 4) {
                Text("\(transcripts.todayWordCount)")
                    .font(.echoMono(13, medium: true))
                    .foregroundStyle(Color.echoText)
                Text("words · \(transcripts.todayEntries.count) dictations")
                    .font(.echo(12))
                    .foregroundStyle(Color.echoSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .echoCard()
    }
}

private struct PermissionsBanner: View {
    let microphone: Bool
    let accessibility: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.echoCoral)
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
