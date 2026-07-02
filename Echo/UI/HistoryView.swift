import AppKit
import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var transcripts: TranscriptStore
    @EnvironmentObject private var settings: SettingsStore
    @State private var query = ""
    @State private var confirmingClear = false

    private var filtered: [TranscriptEntry] {
        guard !query.isEmpty else { return transcripts.entries }
        return transcripts.entries.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if filtered.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filtered) { entry in
                            HistoryRow(entry: entry)
                        }
                    }
                    .padding(.bottom, 16)
                }
            }
        }
        .padding(24)
    }

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.echoSecondary)
                TextField("Search transcripts", text: $query)
                    .textFieldStyle(.plain)
                    .font(.echo(13))
                    .foregroundStyle(Color.echoText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.echoCard))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.echoHairline))

            Spacer()

            if !transcripts.entries.isEmpty {
                Button("Clear History") { confirmingClear = true }
                    .confirmationDialog(
                        "Delete all \(transcripts.entries.count) transcripts?",
                        isPresented: $confirmingClear
                    ) {
                        Button("Delete All", role: .destructive) { transcripts.clear() }
                    } message: {
                        Text("History lives only on this Mac and can't be recovered once deleted.")
                    }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "waveform")
                .font(.system(size: 28))
                .foregroundStyle(Color.echoSecondary.opacity(0.6))
            if transcripts.entries.isEmpty {
                if settings.saveHistory {
                    HStack(spacing: 6) {
                        Text("Nothing here yet — hold")
                        KeycapView(label: settings.hotkey.label)
                        Text("in any app and your words land here.")
                    }
                    .font(.echo(13))
                    .foregroundStyle(Color.echoSecondary)
                } else {
                    Text("History is turned off in Settings.")
                        .font(.echo(13))
                        .foregroundStyle(Color.echoSecondary)
                }
            } else {
                Text("No transcripts match “\(query)”.")
                    .font(.echo(13))
                    .foregroundStyle(Color.echoSecondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

private struct HistoryRow: View {
    let entry: TranscriptEntry
    @State private var isHovering = false
    @State private var justCopied = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.text)
                    .font(.echo(13))
                    .foregroundStyle(Color.echoText)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    Text(entry.date.formatted(.relative(presentation: .named)))
                    Text("·")
                    Text("\(entry.wordCount) words")
                }
                .font(.echoMono(11))
                .foregroundStyle(Color.echoSecondary)
            }
            Spacer()
            if isHovering || justCopied {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.text, forType: .string)
                    justCopied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        justCopied = false
                    }
                } label: {
                    Label(justCopied ? "Copied" : "Copy", systemImage: justCopied ? "checkmark" : "doc.on.doc")
                        .font(.echo(11, .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(justCopied ? Color.green : Color.echoSecondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isHovering ? Color.echoCardHover : Color.echoCard)
        )
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.echoHairline))
        .onHover { isHovering = $0 }
    }
}
