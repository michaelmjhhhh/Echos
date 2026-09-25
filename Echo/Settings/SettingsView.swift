import SwiftUI
import UniformTypeIdentifiers

/// The Settings section of the main window (no longer a separate Settings scene).
struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var models: ModelStore
    @EnvironmentObject private var controller: DictationController
    @EnvironmentObject private var usage: UsageStore
    @State private var inputDevices: [AudioInputDevice] = []
    @State private var pendingDelete: WhisperModel?
    @State private var deviceMonitor: AudioInputDeviceMonitor?
    @State private var deviceRefreshTask: Task<Void, Never>?
    @State private var deviceRefreshID = UUID()
    @State private var confirmClearUsage = false
    @State private var exportNotice: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                settingsCard(eyebrow: "Input") {
                    labeledRow("Microphone") {
                        Picker("", selection: $settings.inputDeviceUID) {
                            Text("System Default").tag(String?.none)
                            ForEach(inputDevices) { device in
                                Text(device.name).tag(String?.some(device.uid))
                            }
                        }
                        .labelsHidden()
                        .frame(width: EchoLayout.settingsControlWidth)
                    }
                    if let name = controller.activeMicrophoneName {
                        footnote("Last used input: \(name)")
                    }
                    if let uid = settings.inputDeviceUID, !inputDevices.contains(where: { $0.uid == uid }) {
                        footnote("Selected microphone is disconnected. Echo uses the system default until it returns.", warning: true)
                    }
                    footnote("The microphone may stay active briefly between dictations for faster starts. Idle audio is discarded.")
                    hairline
                    labeledRow("Dictation key") {
                        Picker("", selection: $settings.hotkey) {
                            ForEach(Hotkey.allCases) { hotkey in
                                Text(hotkey.label).tag(hotkey)
                            }
                        }
                        .labelsHidden()
                        .frame(width: EchoLayout.settingsControlWidth)
                    }
                    if let caveat = settings.hotkey.caveat {
                        // A caveat is a real warning, so it wears the semantic color.
                        footnote(caveat, warning: true)
                    }
                    footnote("Hold the key while speaking; release to insert the transcript at your cursor.")
                }

                settingsCard(eyebrow: "Behavior") {
                    labeledRow("Appearance") {
                        Picker("", selection: $settings.appearance) {
                            ForEach(AppAppearance.allCases) { appearance in
                                Text(appearance.label).tag(appearance)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: EchoLayout.settingsControlWidth)
                    }
                    hairline
                    labeledRow("Start Echo at login") {
                        Toggle("", isOn: $settings.launchAtLogin)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                    if let message = settings.launchAtLoginError { footnote(message, warning: true) }
                    hairline
                    labeledRow("Save dictation history") {
                        Toggle("", isOn: $settings.saveHistory)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                    footnote("Transcripts stay on this Mac. Turning this off does not delete existing history or usage statistics.")
                    hairline
                    labeledRow("Copy transcript to clipboard") {
                        Toggle("", isOn: $settings.copyTranscriptToClipboard)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                    footnote("The latest transcript stays on the clipboard so you can paste it again.")
                }

                recognitionSettings
                usageSettings

                settingsCard(eyebrow: "Model") {
                    ForEach(Array(models.catalog.enumerated()), id: \.element.id) { index, model in
                        if index > 0 { hairline }
                        ModelRow(
                            model: model,
                            isActive: model.variant == settings.modelVariant,
                            isDownloaded: models.isDownloaded(model.variant),
                            isSupported: models.supportedVariants.contains(model.variant),
                            downloadProgress: models.downloadProgress[model.variant],
                            isActivating: controller.pendingModelVariant == model.variant,
                            isEnabled: modelRowsEnabled,
                            onDownload: { Task { await models.download(model.variant) } },
                            onActivate: {
                                Task {
                                    await controller.switchModel(to: model.variant)
                                    // A switch can download files itself — resync disk state.
                                    models.refresh()
                                }
                            },
                            onDelete: { pendingDelete = model }
                        )
                    }
                    if let error = models.lastError {
                        footnote(error, warning: true)
                    }
                    HStack {
                        if controller.canRetry {
                            Button("Retry setup") { Task { await controller.retrySetup() } }
                                .buttonStyle(EchoSecondaryButtonStyle())
                        }
                        Button("Repair current model") { Task { await controller.repairModel(); models.refresh() } }
                            .buttonStyle(EchoSecondaryButtonStyle())
                            .disabled(!modelRowsEnabled)
                    }
                    footnote("Transcription runs on this Mac. Model and language-file installation requires internet access. Repair downloads missing or damaged files.")
                }
            }
            .echoContentColumn()
        }
        .onAppear {
            deviceMonitor = AudioInputDeviceMonitor()
            refreshDevices()
            settings.refreshLaunchAtLoginStatus()
            models.refresh()
        }
        .onDisappear {
            deviceMonitor = nil
            deviceRefreshID = UUID()
            deviceRefreshTask?.cancel()
            deviceRefreshTask = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: AudioInputDevices.changedNotification)) { _ in refreshDevices() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            settings.refreshLaunchAtLoginStatus()
            usage.refresh()
        }
        .confirmationDialog("Delete all usage statistics?", isPresented: $confirmClearUsage) {
            Button("Delete statistics", role: .destructive) { Task { _ = await usage.clear() } }
        } message: {
            Text("This deletes counts, timings and app usage on this Mac. Transcript history is managed separately.")
        }
        .confirmationDialog(
            "Delete \(pendingDelete?.displayName ?? "model")?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { model in
            Button("Delete", role: .destructive) { models.delete(model.variant) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("You can download it again anytime.")
        }
    }

    private var recognitionSettings: some View {
        settingsCard(eyebrow: "Recognition") {
            labeledRow("Spoken language") {
                if WhisperModelCatalog.supportsMultilingual(settings.modelVariant) {
                    Picker("Spoken language", selection: $settings.transcriptionLanguage) {
                        Text("Detect automatically").tag("auto")
                        Text("English").tag("en")
                        Text("Chinese").tag("zh")
                        Text("Spanish").tag("es")
                        Text("French").tag("fr")
                        Text("German").tag("de")
                        Text("Japanese").tag("ja")
                        Text("Korean").tag("ko")
                        Text("Italian").tag("it")
                        Text("Portuguese").tag("pt")
                    }
                    .labelsHidden()
                    .frame(width: EchoLayout.settingsControlWidth)
                } else {
                    Text("English only for this model").font(.echo(12)).foregroundStyle(Color.echoSecondary)
                }
            }
            hairline
            labeledRow("Dictionary hints") {
                Picker("Dictionary hints", selection: $settings.vocabularyTokenBudget) {
                    Text("Off").tag(0)
                    Text("25 tokens").tag(25)
                    Text("50 tokens").tag(50)
                    Text("100 tokens").tag(100)
                    Text("200 tokens (default)").tag(200)
                }
                .labelsHidden()
                .frame(width: EchoLayout.settingsControlWidth)
            }
            footnote("Tokens are small pieces of text. A smaller hint limit may be faster but includes fewer dictionary terms. Star the terms you need most. Saved spelling corrections still apply with hints off.")
            hairline
            labeledRow("Retry difficult speech") {
                Picker("Retry difficult speech", selection: $settings.decodingFallbackCount) {
                    Text("No retries").tag(0)
                    Text("Once").tag(1)
                    Text("Twice").tag(2)
                    Text("Up to 5 times (default)").tag(5)
                }
                .labelsHidden()
                .frame(width: EchoLayout.settingsControlWidth)
            }
            footnote("Fewer retries can reduce waiting on unclear audio and may reduce recognition quality.")
            hairline
            labeledRow("Expand spoken snippets") {
                Toggle("Expand spoken snippets", isOn: $settings.expandSnippets).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            footnote("Turn this off to dictate trigger phrases literally. Each snippet can also be limited to a phrase spoken on its own.")
        }
    }

    private var usageSettings: some View {
        settingsCard(eyebrow: "Usage statistics") {
            labeledRow("Keep local usage statistics") {
                Toggle("Keep local usage statistics", isOn: $settings.saveUsageStatistics).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            footnote("Counts, app identifiers, dates and timing measurements are stored separately from transcript history. Audio and text are never included in statistics. Turning this off stops new records; existing records remain until deleted or expired.")
            labeledRow("Keep statistics for") {
                Picker("Keep statistics for", selection: $settings.usageRetentionDays) {
                    Text("Until I delete them").tag(0)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("1 year").tag(365)
                }
                .labelsHidden()
                .frame(width: EchoLayout.settingsControlWidth)
            }
            HStack {
                Button("Export summary…") { exportUsage() }.buttonStyle(EchoSecondaryButtonStyle())
                Button("Delete statistics…") { confirmClearUsage = true }.buttonStyle(EchoSecondaryButtonStyle(destructive: true))
                    .disabled(usage.isSaving)
            }
            footnote("Export contains aggregate counts and timing ranges, without app names, transcripts, prompts, audio or clipboard content.")
            if let message = usage.persistenceError {
                footnote(message, warning: true)
                Button("Retry saving statistics") { usage.retrySave() }.buttonStyle(EchoSecondaryButtonStyle()).disabled(usage.isSaving)
            }
            if let exportNotice { footnote(exportNotice) }
        }
    }

    private func refreshDevices() {
        deviceRefreshTask?.cancel()
        let id = UUID()
        deviceRefreshID = id
        deviceRefreshTask = Task {
            let devices = await Task.detached(priority: .utility) { AudioInputDevices.all() }.value
            guard !Task.isCancelled, deviceRefreshID == id else { return }
            inputDevices = devices
            deviceRefreshTask = nil
        }
    }

    private func exportUsage() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "echo-usage-summary.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            exportNotice = await usage.exportAggregates(to: url) ? "Summary exported." : "Export failed. Check the error above."
        }
    }

    /// Rows lock together: no activation, download, or delete while a
    /// dictation, model switch, or another download is in flight.
    private var modelRowsEnabled: Bool {
        controller.canSwitchModels && !models.isDownloadingAnything
    }

    private func settingsCard(eyebrow: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            EyebrowText(text: eyebrow)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .echoCard()
    }

    private func labeledRow(_ label: String, @ViewBuilder control: () -> some View) -> some View {
        HStack {
            Text(label)
                .font(.echo(13))
                .foregroundStyle(Color.echoText)
            Spacer()
            control()
        }
        .frame(minHeight: 28)
    }

    private var hairline: some View {
        Rectangle().fill(Color.echoHairline).frame(height: 1)
    }

    private func footnote(_ text: String, warning: Bool = false) -> some View {
        Text(text)
            .font(.echo(11))
            // echoSecondary is already the contrast floor — never dim it further.
            .foregroundStyle(warning ? Color.echoWarning : Color.echoSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One row of the speech-model list: radio for the active model, download
/// button with live percent, trash for downloaded-but-inactive models.
private struct ModelRow: View {
    let model: WhisperModel
    let isActive: Bool
    let isDownloaded: Bool
    let isSupported: Bool
    let downloadProgress: Double?
    let isActivating: Bool
    let isEnabled: Bool
    let onDownload: () -> Void
    let onActivate: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false
    @State private var trashHovering = false

    private var activatesOnTap: Bool {
        isSupported && isEnabled && isDownloaded && !isActive && downloadProgress == nil && !isActivating
    }

    private var caption: String {
        isSupported ? "\(model.sizeLabel) · \(model.detail)" : "Not supported on this Mac"
    }

    var body: some View {
        HStack(spacing: Spacing.s) {
            radio
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)
                    .font(.echo(13))
                    .foregroundStyle(Color.echoText)
                Text(caption)
                    .font(.echoMono(11))
                    .foregroundStyle(Color.echoSecondary)
            }
            Spacer()
            trailing
        }
        .padding(.vertical, Spacing.xxs)
        .frame(minHeight: 28)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(activatesOnTap && isHovering ? Color.echoCardHover : .clear)
                .padding(.horizontal, -Spacing.xs)
        )
        .onTapGesture { if activatesOnTap { onActivate() } }
        .onHover { hovering in
            withAnimation(Motion.ease) { isHovering = hovering }
        }
        .opacity(isSupported ? 1 : 0.4)
        .allowsHitTesting(isSupported)
        .help(activatesOnTap ? "Switch to \(model.displayName)" : "")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityAddTraits(activatesOnTap ? .isButton : [])
    }

    private var accessibilitySummary: String {
        var parts = [model.displayName, model.sizeLabel]
        if !isSupported { parts.append("not supported on this Mac") }
        else if isActive { parts.append("active") }
        else if isDownloaded { parts.append("downloaded") }
        if let downloadProgress {
            parts.append("downloading \(Int(downloadProgress * 100)) percent")
        }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder private var radio: some View {
        if isActivating {
            ProgressView()
                .controlSize(.small)
                .frame(width: 16, height: 16)
        } else {
            ZStack {
                Circle()
                    .strokeBorder(isActive ? Color.echoAccent : Color.echoHairline, lineWidth: 1.5)
                if isActive {
                    Circle()
                        .fill(Color.echoAccent)
                        .frame(width: 6, height: 6)
                }
            }
            .frame(width: 16, height: 16)
        }
    }

    @ViewBuilder private var trailing: some View {
        if let downloadProgress {
            Text("\(Int(downloadProgress * 100))%")
                .font(.echoMono(11, medium: true))
                .foregroundStyle(Color.echoAccent)
        } else if !isDownloaded {
            Button("Download", action: onDownload)
                .buttonStyle(EchoSecondaryButtonStyle())
                .disabled(!isEnabled)
        } else if !isActive {
            Button("Use", action: onActivate)
                .buttonStyle(EchoSecondaryButtonStyle())
                .disabled(!activatesOnTap)
                .accessibilityLabel("Use \(model.displayName)")
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: IconSize.small))
                    .foregroundStyle(trashHovering ? Color.echoWarning : Color.echoSecondary)
            }
            .buttonStyle(EchoPressButtonStyle())
            .disabled(!isEnabled)
            .onHover { hovering in
                withAnimation(Motion.ease) { trashHovering = hovering }
            }
            .help("Delete this model from disk")
            .accessibilityLabel("Delete \(model.displayName)")
        }
    }
}
