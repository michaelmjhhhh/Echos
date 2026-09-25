import SwiftUI

@main
struct EchoApp: App {
    @NSApplicationDelegateAdaptor(EchoAppDelegate.self) private var appDelegate
    @StateObject private var controller: DictationController
    @StateObject private var settings = SettingsStore.shared
    @StateObject private var transcripts: TranscriptStore
    @StateObject private var usage: UsageStore
    @StateObject private var dictionary: DictionaryStore
    @StateObject private var snippets: SnippetStore
    @StateObject private var models: ModelStore

    init() {
        let transcriptStore = TranscriptStore()
        let usageStore = UsageStore()
        let dictionaryStore = DictionaryStore()
        let snippetStore = SnippetStore()
        _transcripts = StateObject(wrappedValue: transcriptStore)
        _usage = StateObject(wrappedValue: usageStore)
        _dictionary = StateObject(wrappedValue: dictionaryStore)
        _snippets = StateObject(wrappedValue: snippetStore)
        _models = StateObject(wrappedValue: ModelStore())
        let controller = DictationController(
            transcripts: transcriptStore,
            usage: usageStore,
            dictionary: dictionaryStore,
            snippets: snippetStore
        )
        _controller = StateObject(wrappedValue: controller)
        appDelegate.controller = controller
        appDelegate.transcripts = transcriptStore
        appDelegate.usage = usageStore
    }

    var body: some Scene {
        Window("Echo", id: "main") {
            MainWindowView()
                .environmentObject(controller)
                .environmentObject(settings)
                .environmentObject(transcripts)
                .environmentObject(usage)
                .environmentObject(dictionary)
                .environmentObject(snippets)
                .environmentObject(models)
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

@MainActor
final class EchoAppDelegate: NSObject, NSApplicationDelegate {
    weak var controller: DictationController?
    weak var transcripts: TranscriptStore?
    weak var usage: UsageStore?
    private var terminationID: UUID?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard terminationID == nil else { return .terminateLater }
        let id = UUID()
        terminationID = id
        controller?.prepareForTermination()
        Task { [weak self] in
            guard let self else { return }
            await self.controller?.drainOperations()
            let historySaved = await self.transcripts?.flushPersistence() ?? true
            let usageSaved = await self.usage?.flushPersistence() ?? true
            guard self.terminationID == id else { return }
            self.terminationID = nil
            if historySaved && usageSaved {
                sender.reply(toApplicationShouldTerminate: true)
            } else {
                self.confirmUnsavedExit(sender)
            }
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, self.terminationID == id else { return }
            self.terminationID = nil
            self.confirmUnsavedExit(sender)
        }
        return .terminateLater
    }

    private func confirmUnsavedExit(_ app: NSApplication) {
        let alert = NSAlert()
        alert.messageText = "Some changes have not been saved"
        alert.informativeText = "Keep Echo open to retry saving. Quitting now may lose recent changes or leave deleted history on disk."
        alert.addButton(withTitle: "Keep Echo Open")
        alert.addButton(withTitle: "Quit Without Saving")
        let quit = alert.runModal() == .alertSecondButtonReturn
        if !quit { controller?.resumeAfterCancelledTermination() }
        app.reply(toApplicationShouldTerminate: quit)
    }
}
