import AppKit
import SwiftUI

/// A single transcript row — shared between History and Home's Recent section.
/// Rows use the card edge treatment but no shadow; only full cards float.
struct TranscriptRow: View {
    let entry: TranscriptEntry
    var compact = false

    @EnvironmentObject private var transcripts: TranscriptStore
    @State private var showingDetail = false
    @State private var correctingAfterDetail = false
    @State private var confirmingDelete = false
    @State private var copyFeedbackTask: Task<Void, Never>?
    @State private var isHovering = false
    @State private var justCopied = false
    @State private var copyFailed = false
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
            VStack(alignment: .trailing, spacing: Spacing.xs) {
                copyButton
                Button("Open") { showingDetail = true }.buttonStyle(EchoPressButtonStyle()).font(.echo(11))
                    .accessibilityLabel("Open full transcript")
            }
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
            Button("Correct a word…") { addingToDictionary = true }
            Button("Open full transcript") { showingDetail = true }
            Button("Delete transcript", role: .destructive) { confirmingDelete = true }
        }
        .sheet(isPresented: $addingToDictionary) {
            DictionaryEditorSheet(entry: nil, sourceTranscript: entry.text)
        }
        .sheet(isPresented: $showingDetail, onDismiss: {
            if correctingAfterDetail {
                correctingAfterDetail = false
                addingToDictionary = true
            }
        }) {
            TranscriptDetailSheet(entry: entry, onCorrect: {
                correctingAfterDetail = true
                showingDetail = false
            })
        }
        .confirmationDialog("Delete this transcript?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { transcripts.delete(entry.id) }
        }
        .onDisappear { copyFeedbackTask?.cancel() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(entry.text)
        .accessibilityValue("\(entry.date.formatted(.relative(presentation: .named))), \(entry.wordCount) words")
        .accessibilityAction(named: "Copy") { copy() }
        .accessibilityAction(named: "Correct a word") { addingToDictionary = true }
        .accessibilityAction(named: "Open full transcript") { showingDetail = true }
        .accessibilityAction(named: "Delete transcript") { confirmingDelete = true }
    }

    private var copyButton: some View {
        Button {
            copy()
        } label: {
            Label(copyFailed ? "Copy failed" : (justCopied ? "Copied" : "Copy"), systemImage: justCopied ? "checkmark" : "doc.on.doc")
                .font(.echo(11, .medium))
        }
        .buttonStyle(EchoPressButtonStyle())
        .focusable()
        .focused($copyFocused)
        .echoFocusRing(copyFocused, radius: Radius.keycap)
        .foregroundStyle(copyFailed ? Color.echoWarning : (justCopied ? Color.echoAccent : Color.echoSecondary))
        .accessibilityLabel("Copy transcript")
        .help("Copy transcript to the clipboard")
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(entry.text, forType: .string) else {
            copyFailed = true
            justCopied = false
            return
        }
        copyFailed = false
        withAnimation(Motion.ease) { justCopied = true }
        copyFeedbackTask?.cancel()
        copyFeedbackTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.ease) { justCopied = false }
        }
    }
}


private struct TranscriptDetailSheet: View {
    let entry: TranscriptEntry
    let onCorrect: () -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var transcripts: TranscriptStore
    @State private var confirmDelete = false
    @State private var copyNotice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(entry.date.formatted(date: .abbreviated, time: .standard)).font(.echoDisplay(16))
            ScrollView {
                Text(entry.text).font(.echo(14)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let copyNotice { Text(copyNotice).font(.echo(12)).foregroundStyle(Color.echoSecondary) }
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    copyNotice = NSPasteboard.general.setString(entry.text, forType: .string)
                        ? "Copied to clipboard." : "Could not copy. Try again."
                }.buttonStyle(EchoSecondaryButtonStyle())
                Button("Correct a word…", action: onCorrect).buttonStyle(EchoSecondaryButtonStyle())
                Button("Delete…") { confirmDelete = true }.buttonStyle(EchoSecondaryButtonStyle(destructive: true))
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(EchoPrimaryButtonStyle()).keyboardShortcut(.cancelAction)
            }
        }
        .padding(Spacing.l).frame(width: 620, height: 440).background(Color.echoBase)
        .confirmationDialog("Delete this transcript?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { transcripts.delete(entry.id); dismiss() }
        }
    }
}
