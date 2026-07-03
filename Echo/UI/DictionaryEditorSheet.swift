import SwiftUI

/// One sheet for adding and editing a dictionary entry. Pass `entry: nil` to
/// add a new word. Validation errors from the store render inline; the sheet
/// only dismisses on a successful save.
struct DictionaryEditorSheet: View {
    let entry: DictionaryEntry?

    @EnvironmentObject private var dictionary: DictionaryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var word = ""
    @State private var misspelling = ""
    @State private var correctsMisspelling = false
    @State private var starred = false
    @State private var error: DictionaryError?
    @FocusState private var wordFocused: Bool
    @FocusState private var misspellingFocused: Bool

    private var trimmedWord: String {
        word.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedWord.isEmpty
            && trimmedWord.count <= DictionaryStore.maxWordLength
            && (!correctsMisspelling
                || !misspelling.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(entry == nil ? "Add word" : "Edit word")
                .font(.echoDisplay(16))
                .tracking(-0.2)
                .foregroundStyle(Color.echoText)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                EyebrowText(text: "Word")
                field("Name, brand, or term", text: $word, focus: $wordFocused, counter: true)
                footnote("Echo listens for this spelling while you dictate.")
            }

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Toggle(isOn: $correctsMisspelling.animation(reduceMotion ? nil : Motion.spring)) {
                    Text("Correct a misspelling")
                        .font(.echo(13))
                        .foregroundStyle(Color.echoText)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                footnote("Echo will replace the misheard version with this word every time.")

                if correctsMisspelling {
                    EyebrowText(text: "Echo mishears it as")
                        .padding(.top, Spacing.xxs)
                    field("e.g. cooper netties", text: $misspelling, focus: $misspellingFocused, counter: false)
                }
            }

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Toggle(isOn: $starred) {
                    Text("Star this word")
                        .font(.echo(13))
                        .foregroundStyle(Color.echoText)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                footnote("Starred words are boosted first when the list is long.")
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
        .frame(width: 380)
        .background(Color.echoBase)
        .onAppear {
            if let entry {
                word = entry.word
                misspelling = entry.misspelling ?? ""
                correctsMisspelling = entry.misspelling != nil
                starred = entry.isStarred
            }
            wordFocused = true
        }
    }

    private func save() {
        let cleanMisspelling = correctsMisspelling ? misspelling : nil
        let result: Result<DictionaryEntry, DictionaryError>
        if var existing = entry {
            existing.word = word
            existing.misspelling = cleanMisspelling
            existing.isStarred = starred
            result = dictionary.update(existing)
        } else {
            result = dictionary.add(word: word, misspelling: cleanMisspelling, starred: starred)
        }
        switch result {
        case .success:
            dismiss()
        case .failure(let saveError):
            withAnimation(reduceMotion ? nil : Motion.spring) { error = saveError }
        }
    }

    // MARK: - Pieces

    private func field(
        _ placeholder: String,
        text: Binding<String>,
        focus: FocusState<Bool>.Binding,
        counter: Bool
    ) -> some View {
        HStack(spacing: 7) {
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.echo(13))
                .foregroundStyle(Color.echoText)
                .focused(focus)
            if counter {
                Text("\(text.wrappedValue.count)/\(DictionaryStore.maxWordLength)")
                    .font(.echoMono(10))
                    .monospacedDigit()
                    .foregroundStyle(
                        text.wrappedValue.count > DictionaryStore.maxWordLength
                            ? Color.echoWarning : Color.echoSecondary
                    )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Color.echoCard))
        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Color.echoHairline))
        .echoFocusRing(focus.wrappedValue)
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.echo(11))
            .foregroundStyle(Color.echoSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
