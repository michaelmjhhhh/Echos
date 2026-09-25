import Foundation

/// Published rule snapshots are immutable. Foundation permits concurrent regex matching.
struct CompiledReplacementRule: @unchecked Sendable {
    let misspelling: String
    let word: String
    let regex: NSRegularExpression
    let allowProtectedText: Bool

    init?(misspelling: String, word: String, allowProtectedText: Bool = false) {
        let normalized = TextRuleMatcher.normalized(misspelling)
        guard !normalized.isEmpty, let regex = TextRuleMatcher.regex(for: normalized) else { return nil }
        self.misspelling = normalized
        self.word = word
        self.regex = regex
        self.allowProtectedText = allowProtectedText
    }
}

struct CompiledSnippetRule: @unchecked Sendable {
    let trigger: String
    let expansion: String
    let regex: NSRegularExpression
    let standaloneOnly: Bool
    let allowProtectedText: Bool

    init?(trigger: String, expansion: String, standaloneOnly: Bool = false, allowProtectedText: Bool = false) {
        let normalized = TextRuleMatcher.normalized(trigger)
        guard !normalized.isEmpty, let regex = TextRuleMatcher.regex(for: normalized) else { return nil }
        self.trigger = normalized
        self.expansion = expansion
        self.regex = regex
        self.standaloneOnly = standaloneOnly
        self.allowProtectedText = allowProtectedText
    }
}

/// Every stage matches its original input. New text is never searched again within that stage.
enum TextRuleMatcher {
    struct Edit {
        let range: NSRange
        let replacement: String
        let priority: Int
    }

    static let maximumOutputUTF16Count = 256_000
    static let maximumMatches = 10_000
    static func normalized(_ text: String) -> String { text.precomposedStringWithCanonicalMapping }
    static func key(_ text: String) -> String { normalized(text).lowercased() }

    static func regex(for literal: String) -> NSRegularExpression? {
        // CJK words do not require whitespace. Latin identifiers do; punctuation-bearing
        // terms such as C++ and .NET still need boundaries outside the complete literal.
        let word = "[\\p{L}\\p{M}\\p{N}_'’]"
        let prefix = literal.unicodeScalars.first.map(isCJK) == true ? "" : "(?<!\(word))"
        let suffix = literal.unicodeScalars.last.map(isCJK) == true ? "" : "(?:(?!\(word))|(?=['’]s(?!\(word))))"
        return try? NSRegularExpression(
            pattern: prefix + NSRegularExpression.escapedPattern(for: literal) + suffix,
            options: [.caseInsensitive]
        )
    }

    static func protectedRanges(in text: String, includeBareDomains: Bool = true) -> [NSRange] {
        let range = NSRange(text.startIndex..., in: text)
        let strict = (protectedRegex.matches(in: text, range: range) + barePathURLRegex.matches(in: text, range: range)).map(\.range)
        return includeBareDomains ? strict + bareDomainRegex.matches(in: text, range: range).map(\.range) : strict
    }

    static func isProtected(_ range: NSRange, ranges: [NSRange]) -> Bool {
        ranges.contains { NSIntersectionRange($0, range).length > 0 }
    }

    static func apply(_ edits: [Edit], to text: String) -> String {
        // Longest match wins, then rule order, then position. Selection is independent
        // of mutation order, including overlapping phrases at different offsets.
        let prioritized = edits.sorted {
            if $0.range.length != $1.range.length { return $0.range.length > $1.range.length }
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            return $0.range.location < $1.range.location
        }
        var selected: [Edit] = []
        var occupied = IndexSet()
        var outputLength = text.utf16.count
        for edit in prioritized {
            let indexes = edit.range.location..<NSMaxRange(edit.range)
            guard !occupied.intersects(integersIn: indexes) else { continue }
            let nextLength = outputLength - edit.range.length + edit.replacement.utf16.count
            // Keep unmatched source text when expansion would exceed the bounded output.
            guard nextLength <= max(maximumOutputUTF16Count, text.utf16.count) else { continue }
            occupied.insert(integersIn: indexes)
            selected.append(edit)
            outputLength = nextLength
        }
        let source = text as NSString
        var result = ""
        result.reserveCapacity(outputLength)
        var cursor = 0
        for edit in selected.sorted(by: { $0.range.location < $1.range.location }) {
            result += source.substring(with: NSRange(location: cursor, length: edit.range.location - cursor))
            result += edit.replacement
            cursor = NSMaxRange(edit.range)
        }
        result += source.substring(from: cursor)
        return result
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x2E80...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0x20000...0x323AF: return true
        default: return false
        }
    }

    private static let barePathURLRegex = try! NSRegularExpression(
        pattern: #"(?:[\p{L}\p{N}](?:[\p{L}\p{N}-]*[\p{L}\p{N}])?\.)+(?:[\p{L}]{2,63}|xn--[A-Z0-9-]+)[/:?#][^\s<>]*"#,
        options: [.caseInsensitive]
    )

    private static let bareDomainRegex = try! NSRegularExpression(
        pattern: #"(?:[\p{L}\p{N}](?:[\p{L}\p{N}-]*[\p{L}\p{N}])?\.)+(?:[\p{L}]{2,63}|xn--[A-Z0-9-]+)(?:[/:?#][^\s<>]*)?"#,
        options: [.caseInsensitive]
    )

    private static let protectedRegex = try! NSRegularExpression(
        pattern: #"```[\s\S]*?(?:```|$)|~~~[\s\S]*?(?:~~~|$)|`[^`\n]*(?:`|$)|(?:[A-Z][A-Z0-9+.-]*://|www\.)[^\s<>]+|[\p{L}\p{N}.!#$%&'*+/=?^_`{|}~-]+@[\p{L}\p{N}](?:[\p{L}\p{N}.-]*[\p{L}\p{N}])?\.[\p{L}]{1,63}"#,
        options: [.caseInsensitive]
    )
}
