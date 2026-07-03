import SwiftUI

@main
struct EchoApp: App {
    @StateObject private var controller: DictationController
    @StateObject private var settings = SettingsStore.shared
    @StateObject private var transcripts: TranscriptStore
    @StateObject private var usage: UsageStore
    @StateObject private var dictionary: DictionaryStore

    init() {
        let transcriptStore = TranscriptStore()
        let usageStore = UsageStore()
        let dictionaryStore = DictionaryStore()
        _transcripts = StateObject(wrappedValue: transcriptStore)
        _usage = StateObject(wrappedValue: usageStore)
        _dictionary = StateObject(wrappedValue: dictionaryStore)
        _controller = StateObject(wrappedValue: DictationController(
            transcripts: transcriptStore,
            usage: usageStore,
            dictionary: dictionaryStore
        ))
    }

    var body: some Scene {
        Window("Echo", id: "main") {
            MainWindowView()
                .environmentObject(controller)
                .environmentObject(settings)
                .environmentObject(transcripts)
                .environmentObject(usage)
                .environmentObject(dictionary)
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
