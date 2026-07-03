import AppKit
import SwiftUI

/// A single transcript row — shared between History and Home's Recent section.
/// Rows use the card edge treatment but no shadow; only full cards float.
struct TranscriptRow: View {
    let entry: TranscriptEntry
    var compact = false

    @State private var isHovering = false
    @State private var justCopied = false
    @State private var addingToDictionary = false
    @FocusState private var copyFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.text)
                    .font(.echo(13))
                    .foregroundStyle(Color.echoText)
                    .lineLimit(compact ? 2 : 3)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                HStack(spacing: Spacing.xs) {
                    Text(entry.date.formatted(.relative(presentation: .named)))
                    Text("·")
                    Text("\(entry.wordCount) words")
                }
                .font(.echoMono(11))
                .foregroundStyle(Color.echoSecondary)
            }
            Spacer(minLength: 0)
            // Visible on hover, when keyboard focus lands on it, and while
            // confirming — never hidden from keyboard users.
            copyButton
                .opacity(isHovering || justCopied || copyFocused ? 1 : 0)
        }
        .padding(Spacing.s)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(isHovering ? Color.echoCardHover : Color.echoCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Color.echoHairline)
        )
        .onHover { hovering in
            withAnimation(Motion.ease) { isHovering = hovering }
        }
        .contextMenu {
            Button("Copy") { copy() }
            // Spotted a word Echo got wrong? Add the right spelling from here.
            Button("Add to Dictionary…") { addingToDictionary = true }
        }
        .sheet(isPresented: $addingToDictionary) {
            DictionaryEditorSheet(entry: nil)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.text)
        .accessibilityValue("\(entry.date.formatted(.relative(presentation: .named))), \(entry.wordCount) words")
        .accessibilityAction(named: "Copy") { copy() }
        .accessibilityAction(named: "Add to Dictionary") { addingToDictionary = true }
    }

    private var copyButton: some View {
        Button {
            copy()
        } label: {
            Label(justCopied ? "Copied" : "Copy", systemImage: justCopied ? "checkmark" : "doc.on.doc")
                .font(.echo(11, .medium))
        }
        .buttonStyle(EchoPressButtonStyle())
        .focusable()
        .focused($copyFocused)
        .echoFocusRing(copyFocused, radius: Radius.keycap)
        .foregroundStyle(justCopied ? Color.echoAccent : Color.echoSecondary)
        .accessibilityLabel("Copy transcript")
        .help("Copy transcript to the clipboard")
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
        withAnimation(Motion.ease) { justCopied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(Motion.ease) { justCopied = false }
        }
    }
}
