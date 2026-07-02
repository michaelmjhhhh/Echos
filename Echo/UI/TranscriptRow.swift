import AppKit
import SwiftUI

/// A single transcript row — shared between History and Home's Recent section.
/// Rows use the card edge treatment but no shadow; only full cards float.
struct TranscriptRow: View {
    let entry: TranscriptEntry
    var compact = false

    @State private var isHovering = false
    @State private var justCopied = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.text)
                    .font(.echo(13))
                    .foregroundStyle(Color.echoText)
                    .lineLimit(compact ? 2 : 3)
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
            Spacer(minLength: 0)
            if isHovering || justCopied {
                copyButton
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isHovering ? Color.echoCardHover : Color.echoCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.echoEdgeTop, .echoEdgeBottom],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        )
        .onHover { hovering in
            withAnimation(Motion.ease) { isHovering = hovering }
        }
    }

    private var copyButton: some View {
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
