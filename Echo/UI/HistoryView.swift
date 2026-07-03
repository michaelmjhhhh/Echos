import AppKit
import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var transcripts: TranscriptStore
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var confirmingClear = false
    @FocusState private var searchFocused: Bool

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
                    LazyVStack(spacing: Spacing.xs) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, entry in
                            TranscriptRow(entry: entry)
                                .echoStagger(index, reduceMotion: reduceMotion)
                        }
                    }
                    .padding(.bottom, Spacing.m)
                    // Re-key on the query so filtering re-runs the entrance stagger.
                    .id(query)
                }
            }
        }
        .echoContentColumn()
        .background(searchShortcut)
    }

    /// Hidden ⌘F — focuses the search field from anywhere in History.
    private var searchShortcut: some View {
        Button("Find") { searchFocused = true }
            .keyboardShortcut("f", modifiers: .command)
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: IconSize.small))
                    .foregroundStyle(Color.echoSecondary)
                    .accessibilityHidden(true)
                TextField("Search transcripts", text: $query)
                    .textFieldStyle(.plain)
                    .font(.echo(13))
                    .foregroundStyle(Color.echoText)
                    .focused($searchFocused)
                    .onExitCommand {
                        // Escape clears the query first, then releases focus.
                        if query.isEmpty {
                            searchFocused = false
                        } else {
                            query = ""
                        }
                    }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Color.echoCard))
            .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Color.echoHairline))
            .echoFocusRing(searchFocused)
            .help("Search transcripts (⌘F)")

            if !query.isEmpty {
                Text(filtered.count == 1 ? "1 match" : "\(filtered.count) matches")
                    .font(.echoMono(10, medium: true))
                    .tracking(0.7)
                    .foregroundStyle(Color.echoSecondary)
                    .monospacedDigit()
            }

            Spacer()

            if !transcripts.entries.isEmpty {
                Button("Clear History") { confirmingClear = true }
                    .buttonStyle(EchoSecondaryButtonStyle(destructive: true))
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
        VStack {
            Spacer()
            if transcripts.entries.isEmpty {
                if settings.saveHistory {
                    EchoEmptyState {
                        HStack(spacing: 6) {
                            Text("Nothing here yet — hold")
                            KeycapView(label: settings.hotkey.label)
                            Text("in any app and your words land here.")
                        }
                    }
                } else {
                    EchoEmptyState {
                        Text("History is turned off in Settings.")
                    }
                }
            } else {
                EchoEmptyState(icon: "magnifyingglass") {
                    Text("No transcripts match “\(query)”.")
                } actions: {
                    Button("Clear Search") {
                        query = ""
                        searchFocused = true
                    }
                    .buttonStyle(EchoSecondaryButtonStyle())
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
