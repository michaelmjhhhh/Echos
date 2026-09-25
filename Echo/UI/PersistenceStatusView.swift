import SwiftUI

/// Failed edits and deletions stay visible until the store confirms durability.
struct PersistenceStatusView: View {
    let error: StorePersistenceError?
    let isSaving: Bool
    let recoveryAvailable: Bool
    let retry: () -> Void
    let recover: () -> Void
    let startFresh: () -> Void
    @State private var confirmReset = false

    var body: some View {
        if let error {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(error.localizedDescription).font(.echo(12)).foregroundStyle(Color.echoWarning).textSelection(.enabled)
                HStack {
                    Button("Retry save", action: retry).buttonStyle(EchoSecondaryButtonStyle())
                    if recoveryAvailable {
                        Button("Recover backup", action: recover).buttonStyle(EchoSecondaryButtonStyle())
                    }
                    if case .corrupt = error {
                        Button("Start fresh…") { confirmReset = true }.buttonStyle(EchoSecondaryButtonStyle(destructive: true))
                    }
                }
                .disabled(isSaving)
            }
            .echoCard()
            .confirmationDialog("Start with an empty collection?", isPresented: $confirmReset) {
                Button("Start fresh", role: .destructive, action: startFresh)
            } message: {
                Text("The damaged original is preserved for recovery. Saved entries will be replaced with an empty collection.")
            }
        } else if isSaving {
            Text("Saving changes…").font(.echo(11)).foregroundStyle(Color.echoSecondary)
        }
    }
}
