import SwiftUI

/// The Settings section of the main window (no longer a separate Settings scene).
struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var models: ModelStore
    @EnvironmentObject private var controller: DictationController
    @State private var inputDevices: [AudioInputDevice] = []
    @State private var pendingDelete: WhisperModel?

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
                    hairline
                    labeledRow("Save dictation history") {
                        Toggle("", isOn: $settings.saveHistory)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                    footnote("History is stored only on this Mac — nothing ever leaves it.")
                }

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
                    footnote("Larger models are more accurate but slower to load and transcribe. All models run fully on-device.")
                }
            }
            .echoContentColumn()
        }
        .onAppear {
            inputDevices = AudioInputDevices.all()
            models.refresh()
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
        .accessibilityElement(children: .ignore)
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
