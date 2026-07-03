import SwiftUI

/// The Settings section of the main window (no longer a separate Settings scene).
struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var inputDevices: [AudioInputDevice] = []

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
                    labeledRow("Speech model") {
                        Text(settings.modelVariant)
                            .font(.echoMono(12))
                            .foregroundStyle(Color.echoSecondary)
                    }
                    footnote("English-optimized Whisper, runs fully on-device. To try another variant: defaults write com.michael.echo modelVariant <name>, then relaunch Echo.")
                }
            }
            .echoContentColumn()
        }
        .onAppear { inputDevices = AudioInputDevices.all() }
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
