import SwiftUI

@main
struct EchoApp: App {
    @StateObject private var controller: DictationController
    @StateObject private var settings = SettingsStore.shared
    @StateObject private var transcripts: TranscriptStore
    @StateObject private var usage: UsageStore

    init() {
        let transcriptStore = TranscriptStore()
        let usageStore = UsageStore()
        _transcripts = StateObject(wrappedValue: transcriptStore)
        _usage = StateObject(wrappedValue: usageStore)
        _controller = StateObject(wrappedValue: DictationController(transcripts: transcriptStore, usage: usageStore))
    }

    var body: some Scene {
        Window("Echo", id: "main") {
            MainWindowView()
                .environmentObject(controller)
                .environmentObject(settings)
                .environmentObject(transcripts)
                .environmentObject(usage)
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
