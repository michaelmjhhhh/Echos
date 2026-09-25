import SwiftUI

/// One sheet for adding and editing a dictionary entry. Pass `entry: nil` to
/// add a new word. Validation errors from the store render inline; the sheet
/// only dismisses on a successful save.
struct DictionaryEditorSheet: View {
    let entry: DictionaryEntry?
    var sourceTranscript: String? = nil

    @EnvironmentObject private var dictionary: DictionaryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var word = ""
    @State private var misspelling = ""
    @State private var correctsMisspelling = false
    @State private var starred = false
    @State private var allowProtectedText = false
    @State private var previewInput = ""
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

            if let sourceTranscript {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    EyebrowText(text: "Original transcript")
                    ScrollView { Text(sourceTranscript).font(.echo(12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 90)
                    Menu("Choose a misheard word") {
                        ForEach(Array(Set(sourceTranscript.split(whereSeparator: { $0.isWhitespace }).map(String.init))).sorted(), id: \.self) { candidate in
                            Button(candidate) { misspelling = candidate.trimmingCharacters(in: .punctuationCharacters); correctsMisspelling = true }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    footnote("Review the misheard text and the intended spelling before saving a correction.")
                }
            }

            VStack(alignment: .leading, spacing: Spacing.xs) {
                EyebrowText(text: "Word")
                field("Name, brand, or term", text: $word, focus: $wordFocused, counter: true)
                footnote("This spelling is a recognition hint. Only an explicit correction below guarantees replacement of a matching phrase.")
            }

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Toggle(isOn: $correctsMisspelling.animation(reduceMotion ? nil : Motion.spring)) {
                    Text("Correct a misspelling")
                        .font(.echo(13))
                        .foregroundStyle(Color.echoText)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                footnote("Matching phrases are corrected after recognition. Links, email addresses and code are protected by default.")

                if correctsMisspelling {
                    EyebrowText(text: "Echo mishears it as")
                        .padding(.top, Spacing.xxs)
                    field("e.g. cooper netties", text: $misspelling, focus: $misspellingFocused, counter: false)
                    Toggle("Also match in links, email and code", isOn: $allowProtectedText).font(.echo(12))
                    rulePreview
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
                allowProtectedText = entry.allowProtectedText
            } else if sourceTranscript != nil {
                correctsMisspelling = true
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
            existing.allowProtectedText = allowProtectedText
            result = dictionary.update(existing)
        } else {
            result = dictionary.add(word: word, misspelling: cleanMisspelling, starred: starred, allowProtectedText: allowProtectedText)
        }
        switch result {
        case .success:
            dismiss()
        case .failure(let saveError):
            withAnimation(reduceMotion ? nil : Motion.spring) { error = saveError }
        }
    }

    private var rulePreview: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            TextField("Try this correction in a sentence", text: $previewInput).textFieldStyle(.roundedBorder).font(.echo(12))
            let sample = previewInput.isEmpty ? misspelling : previewInput
            let rules = CompiledReplacementRule(misspelling: misspelling, word: word, allowProtectedText: allowProtectedText).map { [$0] } ?? []
            Text("Preview: " + ReplacementProcessor(rules: rules).process(sample))
                .font(.echo(12)).foregroundStyle(Color.echoSecondary).textSelection(.enabled).lineLimit(4)
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
