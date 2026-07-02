import SwiftUI

@main
struct EchoApp: App {
    @StateObject private var controller = DictationController()
    @StateObject private var settings = SettingsStore.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(controller)
                .environmentObject(settings)
        } label: {
            Image(systemName: controller.state.menuBarSymbol)
        }

        Settings {
            SettingsView()
                .environmentObject(controller)
                .environmentObject(settings)
        }
    }
}
