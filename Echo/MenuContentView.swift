import SwiftUI

/// Minimal menu bar menu — the main window is the primary UI.
struct MenuContentView: View {
    @EnvironmentObject private var controller: DictationController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(controller.state.statusDescription)

        if controller.canCancel {
            Button(controller.isCancelling ? "Cancelling…" : "Cancel Dictation") { controller.cancelDictation() }
                .disabled(controller.isCancelling)
        }
        if controller.canRetry {
            Button("Retry Setup") { Task { await controller.retrySetup() } }
        }
        if !controller.lastTranscript.isEmpty {
            Button("Copy Last Transcript") { controller.copyTranscript() }
        }
        if let notice = controller.deliveryNotice { Text(notice) }

        Divider()

        Button("Open Echo") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("o")

        Divider()

        Button("Quit Echo") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
