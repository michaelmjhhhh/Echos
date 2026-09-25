import Foundation
import NaturalLanguage
import Tokenizers
import WhisperKit

/// WhisperKit 0.18's wrapper initializer is internal. This small adapter keeps
/// installation/loading strictly local using the public tokenizer protocols.
/// Missing required tokens fail activation instead of fetching another model.
struct LocalWhisperTokenizer: WhisperTokenizer {
    private let tokenizer: any Tokenizer
    let specialTokens: SpecialTokens
    let allLanguageTokens: Set<Int>

    init(tokenizer: any Tokenizer) throws {
        func required(_ token: String) throws -> Int {
            guard let value = tokenizer.convertTokenToId(token) else {
                throw ModelInstallationError.invalidAssets("tokenizer missing \(token)")
            }
            return value
        }
        self.tokenizer = tokenizer
        self.specialTokens = try SpecialTokens(
            endToken: required("<|endoftext|>"), englishToken: required("<|en|>"),
            noSpeechToken: required("<|nospeech|>"), noTimestampsToken: required("<|notimestamps|>"),
            specialTokenBegin: required("<|endoftext|>"), startOfPreviousToken: required("<|startofprev|>"),
            startOfTranscriptToken: required("<|startoftranscript|>"), timeTokenBegin: required("<|0.00|>"),
            transcribeToken: required("<|transcribe|>"), translateToken: required("<|translate|>"),
            whitespaceToken: tokenizer.encode(text: " ").first ?? 220
        )
        let specialBegin = specialTokens.specialTokenBegin
        self.allLanguageTokens = Set(Constants.languages.values.compactMap { tokenizer.convertTokenToId("<|\($0)|>") }.filter { $0 > specialBegin })
    }

    func encode(text: String) -> [Int] { tokenizer.encode(text: text) }
    func decode(tokens: [Int]) -> String { tokenizer.decode(tokens: tokens) }
    func convertTokenToId(_ token: String) -> Int? { tokenizer.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { tokenizer.convertIdToToken(id) }

    func splitToWordTokens(tokenIds: [Int]) -> (words: [String], wordTokens: [[Int]]) {
        let text = decode(tokens: tokenIds.filter { $0 < specialTokens.specialTokenBegin })
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let separateUnicode = ["zh", "ja", "th", "lo", "my", "yue"].contains(recognizer.dominantLanguage?.rawValue ?? "")
        var words: [String] = []
        var groups: [[Int]] = []
        var pending: [Int] = []
        for token in tokenIds {
            pending.append(token)
            let fragment = decode(tokens: pending)
            // A BPE token may contain only part of a Unicode scalar. Keep it
            // with following tokens until decoding produces the whole scalar.
            if fragment.contains("\u{fffd}"), !text.contains("\u{fffd}") { continue }
            let punctuation = !fragment.isEmpty && fragment.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) }
            if separateUnicode || words.isEmpty || fragment.hasPrefix(" ") || punctuation || pending[0] >= specialTokens.specialTokenBegin {
                words.append(fragment)
                groups.append(pending)
            } else {
                words[words.count - 1] += fragment
                groups[groups.count - 1].append(contentsOf: pending)
            }
            pending.removeAll(keepingCapacity: true)
        }
        if !pending.isEmpty { words.append(decode(tokens: pending)); groups.append(pending) }
        return (words, groups)
    }
}
