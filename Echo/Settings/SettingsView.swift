import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                Picker("Dictation key", selection: $settings.hotkey) {
                    ForEach(Hotkey.allCases) { hotkey in
                        Text(hotkey.label).tag(hotkey)
                    }
                }
                if let caveat = settings.hotkey.caveat {
                    Text(caveat)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Text("Hold the key while speaking; release to insert the transcript at your cursor.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Play sounds when recording starts and stops", isOn: $settings.playSounds)
                Toggle("Start Echo at login", isOn: $settings.launchAtLogin)
            }

            Section {
                LabeledContent("Model", value: settings.modelVariant)
                Text("English-optimized Whisper model, runs fully on-device. Restart Echo after changing the model via `defaults write com.michael.echo modelVariant <name>`.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize()
    }
}
