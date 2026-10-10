import SwiftUI

/// One snippet as a full-width row: trigger pill → one-line expansion preview,
/// with edit/delete revealed on hover.
struct SnippetRow: View {
    let snippet: Snippet
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false
    @State private var isHoveringDelete = false
    @State private var confirmingDelete = false
    @FocusState private var editFocused: Bool
    @FocusState private var deleteFocused: Bool

    var body: some View {
        HStack(spacing: Spacing.s) {
            Text("“\(snippet.trigger)”")
                .font(.echo(12, .semibold))
                .foregroundStyle(Color.echoText)
                .lineLimit(1)
                .padding(.horizontal, Spacing.xs)
                .padding(.vertical, Spacing.xxs)
                .background(
                    RoundedRectangle(cornerRadius: Radius.keycap, style: .continuous)
                        .fill(Color.echoCardHover)
                )
                .layoutPriority(1)

            Image(systemName: "arrow.right")
                .font(.system(size: IconSize.caption, weight: .medium))
                .foregroundStyle(Color.echoSecondary)
                .accessibilityHidden(true)

            Text(snippet.expansion)
                .font(.echo(12))
                .foregroundStyle(Color.echoSecondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: Spacing.xs)

            // Same reveal rule as dictionary cards: hover or keyboard focus.
            HStack(spacing: 7) {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.system(size: IconSize.small))
                        .foregroundStyle(Color.echoSecondary)
                }
                .buttonStyle(EchoPressButtonStyle())
                .focusable()
                .focused($editFocused)
                .echoFocusRing(editFocused, radius: Radius.keycap)
                .help("Edit snippet")
                .accessibilityLabel("Edit \(snippet.trigger)")

                Button {
                    confirmingDelete = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: IconSize.small))
                        .foregroundStyle(isHoveringDelete || deleteFocused ? Color.echoWarning : Color.echoSecondary)
                }
                .buttonStyle(EchoPressButtonStyle())
                .focusable()
                .focused($deleteFocused)
                .echoFocusRing(deleteFocused, radius: Radius.keycap)
                .onHover { hovering in
                    withAnimation(Motion.ease) { isHoveringDelete = hovering }
                }
                .help("Delete snippet")
                .accessibilityLabel("Delete \(snippet.trigger)")
            }
            .opacity(isHovering || editFocused || deleteFocused ? 1 : 0)
        }
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(isHovering ? Color.echoCardHover : Color.echoCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Color.echoHairline)
        )
        .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        // Single click edits, matching dictionary cards.
        .onTapGesture(perform: onEdit)
        .onHover { hovering in
            withAnimation(Motion.ease) { isHovering = hovering }
        }
        .help("Edit “\(snippet.trigger)”")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Snippet \(snippet.trigger)")
        .accessibilityValue(snippet.expansion)
        .accessibilityAction(named: "Edit snippet", onEdit)
        .accessibilityAction(named: "Delete snippet") { confirmingDelete = true }
        .confirmationDialog("Delete “\(snippet.trigger)”?", isPresented: $confirmingDelete) {
            Button("Delete snippet", role: .destructive, action: onDelete)
        } message: {
            Text("Saying this phrase will no longer insert the saved text.")
        }
    }
}
