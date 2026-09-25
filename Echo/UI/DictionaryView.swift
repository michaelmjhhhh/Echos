import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Dictionary section: the user's personal vocabulary as a specimen sheet
/// of headword cards. Words here are boosted during recognition; entries with
/// a misspelling rule are corrected after transcription.
struct DictionaryView: View {
    @EnvironmentObject private var dictionary: DictionaryStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var editorTarget: EditorTarget?
    @State private var importSummary: String?
    @State private var importSummaryClearTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool

    /// Sheet payload: `entry == nil` adds a new word, otherwise edits.
    struct EditorTarget: Identifiable {
        let id: UUID
        let entry: DictionaryEntry?

        static var newWord: EditorTarget { EditorTarget(id: UUID(), entry: nil) }
        static func edit(_ entry: DictionaryEntry) -> EditorTarget {
            EditorTarget(id: entry.id, entry: entry)
        }
    }

    private var filtered: [DictionaryEntry] {
        let base = dictionary.sortedEntries
        guard !query.isEmpty else { return base }
        return base.filter {
            $0.word.localizedCaseInsensitiveContains(query)
                || ($0.misspelling?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            PersistenceStatusView(error: dictionary.persistenceError, isSaving: dictionary.isSaving,
                recoveryAvailable: dictionary.recoveryAvailable,
                retry: { _ = dictionary.retrySave() }, recover: { _ = dictionary.recoverFromBackup() },
                startFresh: { _ = dictionary.startFresh() })
            if !dictionary.conflictingAliases.isEmpty {
                Text("Conflicting corrections are paused: " + dictionary.conflictingAliases.joined(separator: ", ") + ". Edit these entries to keep one destination per phrase.")
                    .font(.echo(12)).foregroundStyle(Color.echoWarning)
            }
            if dictionary.entries.isEmpty {
                firstRunEmptyState
            } else {
                content
            }
        }
        .echoContentColumn()
        .background(hiddenShortcuts)
        .sheet(item: $editorTarget) { target in
            DictionaryEditorSheet(entry: target.entry)
        }
        .onDisappear { importSummaryClearTask?.cancel() }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            statLine

            if filtered.isEmpty {
                noMatchesState
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 200), spacing: Spacing.xs)],
                        spacing: Spacing.xs
                    ) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, entry in
                            DictionaryEntryCard(
                                entry: entry,
                                onToggleStar: { dictionary.toggleStar(entry.id) },
                                onEdit: { editorTarget = .edit(entry) },
                                onDelete: { dictionary.delete(entry.id) }
                            )
                            .echoStagger(index, reduceMotion: reduceMotion)
                        }
                    }
                    .padding(.bottom, Spacing.m)
                    // Re-key on query and sort so changes re-run the entrance stagger.
                    .id(query + dictionary.sort.rawValue)
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: IconSize.small))
                    .foregroundStyle(Color.echoSecondary)
                    .accessibilityHidden(true)
                TextField("Search words", text: $query)
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
            .help("Search words (⌘F)")

            if !query.isEmpty {
                Text(filtered.count == 1 ? "1 match" : "\(filtered.count) matches")
                    .font(.echoMono(10, medium: true))
                    .tracking(0.7)
                    .foregroundStyle(Color.echoSecondary)
                    .monospacedDigit()
            }

            Spacer()

            sortMenu

            Button("Import…") { importWords() }
                .buttonStyle(EchoSecondaryButtonStyle())
                .help("Import words from a plain-text file, one per line")

            Button("Add word") { editorTarget = .newWord }
                .buttonStyle(EchoPrimaryButtonStyle())
                .help("Add a word to the dictionary (⌘N)")
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $dictionary.sort) {
                ForEach(DictionarySort.allCases) { sort in
                    Text(sort.label).tag(sort)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: Spacing.xxs) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: IconSize.caption))
                Text(dictionary.sort.label)
                    .font(.echo(12, .medium))
            }
            .foregroundStyle(Color.echoText)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, Spacing.xxs + 1)
        .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Color.echoCard))
        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Color.echoHairline))
        .help("Change how words are sorted")
        .accessibilityLabel("Sort words, currently \(dictionary.sort.label)")
    }

    /// The dashboard: one honest mono line — counts this small don't earn charts.
    private var statLine: some View {
        HStack(spacing: Spacing.xs) {
            EyebrowText(text: [
                count(dictionary.entries.count, "word"),
                count(dictionary.starredCount, "starred", pluralize: false),
                count(dictionary.replacementCount, "replacement"),
            ].joined(separator: " · "))
            .monospacedDigit()
            .accessibilityLabel(
                "\(dictionary.entries.count) words, \(dictionary.starredCount) starred, \(dictionary.replacementCount) replacements"
            )

            if let importSummary {
                EyebrowText(text: "— \(importSummary)")
                    .monospacedDigit()
                    .transition(.opacity)
            }
        }
    }

    // MARK: - Import

    /// Validate the entire import before one durable mutation. Duplicate words are skipped.
    private func importWords() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a plain-text file with one word per line."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 3_000_000 else {
            showImportSummary("Choose a plain-text file under 3 MB.")
            return
        }
        Task {
            let content = await Task.detached(priority: .userInitiated) { try? String(contentsOf: url, encoding: .utf8) }.value
            guard let content, content.utf8.count <= 3_000_000 else {
                showImportSummary("Could not read the file. Use UTF-8 plain text under 3 MB.")
                return
            }
            switch dictionary.importWords(content.components(separatedBy: .newlines)) {
            case .success(let added): showImportSummary("Imported \(count(added, "word")). Duplicates were skipped.")
            case .failure(let error): showImportSummary("Import was not saved. \(error.localizedDescription)")
            }
        }
    }

    private func showImportSummary(_ text: String) {
        withAnimation(reduceMotion ? nil : Motion.spring) { importSummary = text }
        importSummaryClearTask?.cancel()
        importSummaryClearTask = Task {
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : Motion.exit) { importSummary = nil }
        }
    }

    private func count(_ n: Int, _ noun: String, pluralize: Bool = true) -> String {
        "\(n) \(pluralize && n != 1 ? noun + "s" : noun)"
    }

    // MARK: - Empty states

    private var firstRunEmptyState: some View {
        VStack {
            Spacer()
            EchoEmptyState(icon: "character.book.closed") {
                Text("Echo types what it hears. Teach it the words it can't guess — names, brands, jargon.")
            } actions: {
                Button("Add word") { editorTarget = .newWord }
                    .buttonStyle(EchoPrimaryButtonStyle())
                Button("Import…") { importWords() }.buttonStyle(EchoSecondaryButtonStyle())
            }
            if let importSummary {
                Text(importSummary).font(.echo(12)).foregroundStyle(Color.echoSecondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var noMatchesState: some View {
        VStack {
            Spacer()
            EchoEmptyState(icon: "magnifyingglass") {
                Text("No words match “\(query)”.")
            } actions: {
                Button("Clear Search") {
                    query = ""
                    searchFocused = true
                }
                .buttonStyle(EchoSecondaryButtonStyle())
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Shortcuts

    /// Hidden ⌘F (focus search) and ⌘N (add word).
    private var hiddenShortcuts: some View {
        Group {
            Button("Find") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
            Button("Add word") { editorTarget = .newWord }
                .keyboardShortcut("n", modifiers: .command)
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
