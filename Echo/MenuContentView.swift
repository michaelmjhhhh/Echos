import SwiftUI

/// Minimal menu bar menu — the main window is the primary UI.
struct MenuContentView: View {
    @EnvironmentObject private var controller: DictationController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(controller.state.statusDescription)

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
