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

    /// Filtered entries split by calendar day, newest first. Each row keeps
    /// its overall position so the entrance stagger runs top to bottom.
    private var dayGroups: [(day: Date, title: String, entries: [(index: Int, entry: TranscriptEntry)])] {
        let calendar = Calendar.current
        var groups: [(day: Date, title: String, entries: [(index: Int, entry: TranscriptEntry)])] = []
        for (index, entry) in filtered.enumerated() {
            let day = calendar.startOfDay(for: entry.date)
            if groups.last?.day == day {
                groups[groups.count - 1].entries.append((index, entry))
            } else {
                groups.append((day, dayTitle(day, calendar: calendar), [(index, entry)]))
            }
        }
        return groups
    }

    private func dayTitle(_ day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        if calendar.isDate(day, equalTo: Date(), toGranularity: .year) {
            return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        }
        return day.formatted(date: .abbreviated, time: .omitted)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            PersistenceStatusView(error: transcripts.persistenceError, isSaving: transcripts.isSaving,
                recoveryAvailable: transcripts.recoveryAvailable,
                retry: { Task { _ = await transcripts.retrySave() } },
                recover: { _ = transcripts.recoverFromBackup() },
                startFresh: { Task { _ = await transcripts.startFresh() } })

            if filtered.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Spacing.xs) {
                        ForEach(Array(dayGroups.enumerated()), id: \.element.day) { groupIndex, group in
                            EyebrowText(text: group.title)
                                .padding(.top, groupIndex == 0 ? 0 : Spacing.s)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(group.entries, id: \.entry.id) { item in
                                TranscriptRow(entry: item.entry)
                                    .echoStagger(item.index, reduceMotion: reduceMotion)
                            }
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
            EchoSearchField(
                prompt: "Search transcripts",
                text: $query,
                focus: $searchFocused,
                matchCount: query.isEmpty ? nil : filtered.count
            )
            .help("Search transcripts (⌘F)")

            Spacer()

            if !transcripts.entries.isEmpty {
                Button("Clear history") { confirmingClear = true }
                    .buttonStyle(EchoSecondaryButtonStyle(destructive: true))
                    .confirmationDialog(
                        "Delete all \(transcripts.entries.count) transcripts?",
                        isPresented: $confirmingClear
                    ) {
                        Button("Delete all", role: .destructive) { Task { _ = await transcripts.clearPersisted() } }
                    } message: {
                        Text("This deletes saved transcripts on this Mac. Usage statistics are managed separately in Settings.")
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
                    Button("Clear search") {
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
