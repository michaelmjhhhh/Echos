import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var inputDevices: [AudioInputDevice] = []

    var body: some View {
        Form {
            Section {
                Picker("Microphone", selection: $settings.inputDeviceUID) {
                    Text("System Default").tag(String?.none)
                    ForEach(inputDevices) { device in
                        Text(device.name).tag(String?.some(device.uid))
                    }
                }
                Text("“System Default” follows whatever macOS is currently using — pick a specific device if a Bluetooth mic (e.g. AirPods) misbehaves.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

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
        .onAppear { inputDevices = AudioInputDevices.all() }
    }
}
