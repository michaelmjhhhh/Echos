import SwiftUI

/// One dictionary entry as a specimen card: the word set as a headword in the
/// display face, with a mono annotation line underneath — the replacement rule
/// it fixes, or when it was added. Clicking the card opens the editor.
struct DictionaryEntryCard: View {
    let entry: DictionaryEntry
    let onToggleStar: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false
    @State private var isHoveringDelete = false
    @State private var confirmingDelete = false
    @FocusState private var starFocused: Bool
    @FocusState private var editFocused: Bool
    @FocusState private var deleteFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Headword anchors the card's left edge; actions live at the
            // trailing edge so the hidden state leaves no phantom indent.
            HStack(spacing: 7) {
                Text(entry.word)
                    .font(.echoDisplay(15))
                    .tracking(-0.2)
                    .foregroundStyle(Color.echoText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                starButton
                editButton
                deleteButton
            }
            annotation
        }
        .padding(Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(isHovering ? Color.echoCardHover : Color.echoCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Color.echoHairline)
        )
        .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .onTapGesture(perform: onEdit)
        .onHover { hovering in
            withAnimation(Motion.ease) { isHovering = hovering }
        }
        .help("Edit “\(entry.word)”")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.word)
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onEdit() }
        .accessibilityAction(named: entry.isStarred ? "Unstar" : "Star") { onToggleStar() }
        .accessibilityAction(named: "Delete") { confirmingDelete = true }
        .confirmationDialog("Remove “\(entry.word)”?", isPresented: $confirmingDelete) {
            Button("Remove Word", role: .destructive, action: onDelete)
        } message: {
            Text("Echo will stop boosting this word immediately.")
        }
    }

    /// Mono annotation slot: what this entry fixes, or when it arrived.
    private var annotation: some View {
        Group {
            if let misspelling = entry.misspelling {
                Text("replaces “\(misspelling)”")
            } else {
                Text("added \(entry.dateAdded.formatted(.relative(presentation: .named)))")
            }
        }
        .font(.echoMono(11))
        .foregroundStyle(Color.echoSecondary)
        .lineLimit(1)
        .truncationMode(.tail)
    }

    private var accessibilityValue: String {
        var parts: [String] = []
        if entry.isStarred { parts.append("starred") }
        if let misspelling = entry.misspelling { parts.append("replaces \(misspelling)") }
        parts.append("added \(entry.dateAdded.formatted(.relative(presentation: .named)))")
        return parts.joined(separator: ", ")
    }

    // MARK: - Hover-revealed actions (never hidden from keyboard users)

    private var starButton: some View {
        Button(action: onToggleStar) {
            Image(systemName: entry.isStarred ? "star.fill" : "star")
                .font(.system(size: IconSize.small))
                .foregroundStyle(entry.isStarred ? Color.echoAccent : Color.echoSecondary)
        }
        .buttonStyle(EchoPressButtonStyle())
        .focusable()
        .focused($starFocused)
        .echoFocusRing(starFocused, radius: Radius.keycap)
        .opacity(entry.isStarred || isHovering || starFocused ? 1 : 0)
        .help(entry.isStarred ? "Unstar — starred words are boosted first" : "Star — boost this word first")
        .accessibilityHidden(true) // covered by the card's custom action
    }

    private var editButton: some View {
        Button(action: onEdit) {
            Image(systemName: "pencil")
                .font(.system(size: IconSize.small))
                .foregroundStyle(Color.echoSecondary)
        }
        .buttonStyle(EchoPressButtonStyle())
        .focusable()
        .focused($editFocused)
        .echoFocusRing(editFocused, radius: Radius.keycap)
        .opacity(isHovering || editFocused ? 1 : 0)
        .help("Edit this word")
        .accessibilityHidden(true)
    }

    private var deleteButton: some View {
        Button {
            confirmingDelete = true
        } label: {
            Image(systemName: "trash")
                .font(.system(size: IconSize.small))
                // Warning color only when the trash itself is targeted —
                // resting state stays quiet like the other actions.
                .foregroundStyle(isHoveringDelete || deleteFocused ? Color.echoWarning : Color.echoSecondary)
        }
        .buttonStyle(EchoPressButtonStyle())
        .focusable()
        .focused($deleteFocused)
        .echoFocusRing(deleteFocused, radius: Radius.keycap)
        .opacity(isHovering || deleteFocused ? 1 : 0)
        .onHover { hovering in
            withAnimation(Motion.ease) { isHoveringDelete = hovering }
        }
        .help("Remove this word")
        .accessibilityHidden(true)
    }
}
