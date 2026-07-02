import SwiftUI

struct MenuContentView: View {
    @EnvironmentObject private var controller: DictationController
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Text(controller.state.statusDescription)

        if case .needsPermissions(let mic, let ax) = controller.state {
            if !mic {
                Button("Open Microphone Settings…") { Permissions.openMicrophoneSettings() }
            }
            if !ax {
                Button("Open Accessibility Settings…") { Permissions.openAccessibilitySettings() }
            }
        }

        if !controller.lastTranscript.isEmpty {
            Divider()
            Text("Last: \(controller.lastTranscript.prefix(60))")
        }

        Divider()

        Picker("Microphone", selection: $settings.inputDeviceUID) {
            Text("System Default").tag(String?.none)
            ForEach(AudioInputDevices.all()) { device in
                Text(device.name).tag(String?.some(device.uid))
            }
        }

        Toggle("Start at Login", isOn: $settings.launchAtLogin)
        Toggle("Sounds", isOn: $settings.playSounds)

        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",")

        Divider()

        Button("Quit Echo") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
