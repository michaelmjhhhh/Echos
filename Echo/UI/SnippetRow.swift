import SwiftUI

/// One snippet as a full-width row: trigger pill → one-line expansion preview,
/// with edit/delete revealed on hover.
struct SnippetRow: View {
    let snippet: Snippet
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Spacing.s) {
            Text("“\(snippet.trigger)”")
                .font(.echo(12, .semibold))
                .foregroundStyle(Color.echoText)
                .lineLimit(1)
                .padding(.horizontal, Spacing.xs)
                .padding(.vertical, Spacing.xxs)
                .background(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
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

            if isHovering {
                HStack(spacing: Spacing.xxs) {
                    Button(action: onEdit) {
                        Image(systemName: "pencil")
                            .font(.system(size: IconSize.small))
                    }
                    .buttonStyle(EchoPressButtonStyle())
                    .help("Edit snippet")
                    .accessibilityLabel("Edit \(snippet.trigger)")

                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: IconSize.small))
                    }
                    .buttonStyle(EchoPressButtonStyle())
                    .help("Delete snippet")
                    .accessibilityLabel("Delete \(snippet.trigger)")
                }
                .foregroundStyle(Color.echoSecondary)
                .transition(.opacity)
            }
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
        .onTapGesture(count: 2, perform: onEdit)
        .onHover { hovering in
            withAnimation(Motion.ease) { isHovering = hovering }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Snippet \(snippet.trigger)")
        .accessibilityValue(snippet.expansion)
    }
}
