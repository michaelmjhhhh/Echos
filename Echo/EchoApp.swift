import SwiftUI

@main
struct EchoApp: App {
    @StateObject private var controller: DictationController
    @StateObject private var settings = SettingsStore.shared
    @StateObject private var transcripts: TranscriptStore

    init() {
        let store = TranscriptStore()
        _transcripts = StateObject(wrappedValue: store)
        _controller = StateObject(wrappedValue: DictationController(transcripts: store))
    }

    var body: some Scene {
        Window("Echo", id: "main") {
            MainWindowView()
                .environmentObject(controller)
                .environmentObject(settings)
                .environmentObject(transcripts)
        }
        .defaultSize(width: 760, height: 620)

        MenuBarExtra {
            MenuContentView()
                .environmentObject(controller)
        } label: {
            Image(systemName: controller.state.menuBarSymbol)
        }
    }
}
