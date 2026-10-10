import SwiftUI

/// The Snippets section: saved text blocks inserted by saying their trigger
/// phrase while dictating. Rows read left-to-right as "say this → get this".
struct SnippetsView: View {
    @EnvironmentObject private var snippets: SnippetStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var editorTarget: EditorTarget?
    @FocusState private var searchFocused: Bool

    /// Sheet payload: `snippet == nil` adds a new snippet, otherwise edits.
    struct EditorTarget: Identifiable {
        let id: UUID
        let snippet: Snippet?

        static var newSnippet: EditorTarget { EditorTarget(id: UUID(), snippet: nil) }
        static func edit(_ snippet: Snippet) -> EditorTarget {
            EditorTarget(id: snippet.id, snippet: snippet)
        }
    }

    private var filtered: [Snippet] {
        guard !query.isEmpty else { return snippets.entries }
        return snippets.entries.filter {
            $0.trigger.localizedCaseInsensitiveContains(query)
                || $0.expansion.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            PersistenceStatusView(error: snippets.persistenceError, isSaving: snippets.isSaving,
                recoveryAvailable: snippets.recoveryAvailable,
                retry: { _ = snippets.retrySave() }, recover: { _ = snippets.recoverFromBackup() },
                startFresh: { _ = snippets.startFresh() })
            if snippets.entries.isEmpty {
                firstRunEmptyState
            } else {
                content
            }
        }
        .echoContentColumn()
        .background(hiddenShortcuts)
        .sheet(item: $editorTarget) { target in
            SnippetEditorSheet(snippet: target.snippet)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            statLine

            if filtered.isEmpty {
                noMatchesState
            } else {
                ScrollView {
                    LazyVStack(spacing: Spacing.xs) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, snippet in
                            SnippetRow(
                                snippet: snippet,
                                onEdit: { editorTarget = .edit(snippet) },
                                onDelete: { snippets.delete(snippet.id) }
                            )
                            .echoStagger(index, reduceMotion: reduceMotion)
                        }
                    }
                    .padding(.bottom, Spacing.m)
                    // Re-key on query so changes re-run the entrance stagger.
                    .id(query)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            EchoSearchField(
                prompt: "Search snippets",
                text: $query,
                focus: $searchFocused,
                matchCount: query.isEmpty ? nil : filtered.count
            )
            .help("Search snippets (⌘F)")

            Spacer()

            Button("Add snippet") { editorTarget = .newSnippet }
                .buttonStyle(EchoPrimaryButtonStyle())
                .help("Add a snippet (⌘N)")
        }
    }

    private var statLine: some View {
        EyebrowText(text: echoCount(snippets.entries.count, "snippet"))
            .monospacedDigit()
            .accessibilityLabel(echoCount(snippets.entries.count, "snippet"))
    }

    // MARK: - Empty states

    private var firstRunEmptyState: some View {
        VStack {
            Spacer()
            EchoEmptyState(icon: "text.insert") {
                Text("Save text you type often — an email, a link, a prompt — then say its trigger phrase to drop it in.")
            } actions: {
                Button("Add snippet") { editorTarget = .newSnippet }
                    .buttonStyle(EchoPrimaryButtonStyle())
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var noMatchesState: some View {
        VStack {
            Spacer()
            EchoEmptyState(icon: "magnifyingglass") {
                Text("No snippets match “\(query)”.")
            } actions: {
                Button("Clear search") {
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

    /// Hidden ⌘F (focus search) and ⌘N (add snippet).
    private var hiddenShortcuts: some View {
        Group {
            Button("Find") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
            Button("Add snippet") { editorTarget = .newSnippet }
                .keyboardShortcut("n", modifiers: .command)
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
