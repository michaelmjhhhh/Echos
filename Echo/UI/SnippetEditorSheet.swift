import SwiftUI

/// One sheet for adding and editing a snippet. Pass `snippet: nil` to add.
/// Validation errors from the store render inline; the sheet only dismisses
/// on a successful save.
struct SnippetEditorSheet: View {
    let snippet: Snippet?

    @EnvironmentObject private var snippets: SnippetStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var trigger = ""
    @State private var expansion = ""
    @State private var error: SnippetError?
    @FocusState private var triggerFocused: Bool
    @FocusState private var expansionFocused: Bool

    private var canSave: Bool {
        let cleanTrigger = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanExpansion = expansion.trimmingCharacters(in: .whitespacesAndNewlines)
        return !cleanTrigger.isEmpty
            && cleanTrigger.count <= SnippetStore.maxTriggerLength
            && !cleanExpansion.isEmpty
            && cleanExpansion.count <= SnippetStore.maxExpansionLength
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(snippet == nil ? "Add snippet" : "Edit snippet")
                .font(.echoDisplay(16))
                .tracking(-0.2)
                .foregroundStyle(Color.echoText)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                EyebrowText(text: "When you say")
                HStack(spacing: 7) {
                    TextField("e.g. my email address", text: $trigger)
                        .textFieldStyle(.plain)
                        .font(.echo(13))
                        .foregroundStyle(Color.echoText)
                        .focused($triggerFocused)
                    Text("\(trigger.count)/\(SnippetStore.maxTriggerLength)")
                        .font(.echoMono(10))
                        .monospacedDigit()
                        .foregroundStyle(
                            trigger.count > SnippetStore.maxTriggerLength
                                ? Color.echoWarning : Color.echoSecondary
                        )
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Color.echoCard))
                .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Color.echoHairline))
                .echoFocusRing(triggerFocused)
                footnote("Echo listens for this phrase while you dictate — on its own or inside a sentence.")
            }

            VStack(alignment: .leading, spacing: Spacing.xs) {
                EyebrowText(text: "Echo types")
                TextEditor(text: $expansion)
                    .font(.echo(13))
                    .foregroundStyle(Color.echoText)
                    .scrollContentBackground(.hidden)
                    .focused($expansionFocused)
                    .frame(height: 96)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Color.echoCard))
                    .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Color.echoHairline))
                    .echoFocusRing(expansionFocused)
                HStack {
                    footnote("Inserted exactly as written — links, emails, and prompts keep their casing.")
                    Spacer()
                    Text("\(expansion.count)/\(SnippetStore.maxExpansionLength)")
                        .font(.echoMono(10))
                        .monospacedDigit()
                        .foregroundStyle(
                            expansion.count > SnippetStore.maxExpansionLength
                                ? Color.echoWarning : Color.echoSecondary
                        )
                }
            }

            if let error {
                Text(error.localizedDescription)
                    .font(.echo(11))
                    .foregroundStyle(Color.echoWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Spacing.xs) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(EchoSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .buttonStyle(EchoPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
                    .opacity(canSave ? 1 : 0.5)
            }
        }
        .padding(Spacing.l)
        .frame(width: 420)
        .background(Color.echoBase)
        .onAppear {
            if let snippet {
                trigger = snippet.trigger
                expansion = snippet.expansion
            }
            triggerFocused = true
        }
    }

    private func save() {
        let result: Result<Snippet, SnippetError>
        if var existing = snippet {
            existing.trigger = trigger
            existing.expansion = expansion
            result = snippets.update(existing)
        } else {
            result = snippets.add(trigger: trigger, expansion: expansion)
        }
        switch result {
        case .success:
            dismiss()
        case .failure(let saveError):
            withAnimation(reduceMotion ? nil : Motion.spring) { error = saveError }
        }
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.echo(11))
            .foregroundStyle(Color.echoSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
