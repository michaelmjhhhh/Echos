import Foundation
import AVFoundation
import CryptoKit
import WhisperKit

/// A local replay executable sharing the app's ASR, trim and text-processing code.
/// It does not open the app's dictionary, history, defaults or microphone.
@main
struct EchoEvaluate {
    static func main() async {
        do {
            let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
            if options.help { print(Options.usage); return }
            try await run(options)
        } catch {
            FileHandle.standardError.write(Data("EchoEvaluate: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func run(_ options: Options) async throws {
        guard let manifestURL = options.manifest else { throw EvaluationError.invalid("--manifest is required. Use --help for the schema.") }
        let manifestData = try boundedRead(manifestURL, maximumBytes: 4 * 1_024 * 1_024)
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        guard !manifest.cases.isEmpty, manifest.cases.count <= 1_000 else { throw EvaluationError.invalid("A manifest must contain 1–1,000 cases.") }
        guard Set(manifest.cases.map(\.id)).count == manifest.cases.count else { throw EvaluationError.invalid("Case IDs must be unique.") }
        let vocabulary = manifest.vocabulary ?? []
        guard vocabulary.count <= 1_000, vocabulary.allSatisfy({ $0.count <= 60 }) else { throw EvaluationError.invalid("Vocabulary is limited to 1,000 words of 60 characters each.") }
        let replacements = try (manifest.replacements ?? []).map { rule -> CompiledReplacementRule in
            guard !rule.from.isEmpty, rule.from.count <= 60, rule.to.count <= 60,
                  let compiled = CompiledReplacementRule(misspelling: rule.from, word: rule.to, allowProtectedText: rule.allowProtectedText ?? false) else {
                throw EvaluationError.invalid("Invalid replacement rule.")
            }
            return compiled
        }
        let snippets = try (manifest.snippets ?? []).map { rule -> CompiledSnippetRule in
            guard !rule.trigger.isEmpty, rule.trigger.count <= 60, rule.expansion.count <= 4_000,
                  let compiled = CompiledSnippetRule(trigger: rule.trigger, expansion: rule.expansion, standaloneOnly: rule.standaloneOnly ?? false, allowProtectedText: rule.allowProtectedText ?? false) else {
                throw EvaluationError.invalid("Invalid snippet rule.")
            }
            return compiled
        }
        guard replacements.count <= 1_000, snippets.count <= 1_000 else { throw EvaluationError.invalid("At most 1,000 rules per stage are supported.") }
        guard Set(replacements.map { TextRuleMatcher.key($0.misspelling) }).count == replacements.count,
              Set(snippets.map { TextRuleMatcher.key($0.trigger) }).count == snippets.count else {
            throw EvaluationError.invalid("Duplicate rule aliases or snippet triggers are ambiguous.")
        }
        let processors: [any TextProcessor] = [WhitespaceCleanupProcessor(), ReplacementProcessor(rules: replacements), SnippetProcessor(rules: snippets)]
        let configuration = CaptureConfiguration.default
        let trimmer = VoiceActivityTrimmer(configuration: configuration)
        var rows: [[String: Any]] = []
        var failures = 0
        var replayIndex = 0
        let started = ProcessInfo.processInfo.systemUptime
        let service = TranscriptionService(modelVariant: options.model, downloadBase: options.downloadBase)
        var modelFingerprint: String?
        var tokenizerFingerprint: String?
        var preparationSeconds = 0.0
        var loadingSeconds = 0.0
        if !options.validateOnly {
            let preparationStart = ProcessInfo.processInfo.systemUptime
            if options.download {
                try await service.prepare(progress: { _ in })
            } else {
                try await service.prepareInstalled()
            }
            preparationSeconds = ProcessInfo.processInfo.systemUptime - preparationStart
            let loadStart = ProcessInfo.processInfo.systemUptime
            try await service.loadModel()
            loadingSeconds = ProcessInfo.processInfo.systemUptime - loadStart
            let folder = WhisperModelPaths.modelFolder(for: options.model, downloadBase: options.downloadBase)
            modelFingerprint = try fingerprintDirectory(folder)
            if let tokenizerFolder = WhisperModelPaths.localTokenizerFolder(for: options.model, downloadBase: options.downloadBase) {
                var identity = ""
                for name in ["tokenizer.json", "tokenizer_config.json", "config.json", "special_tokens_map.json", "added_tokens.json"] {
                    let file = tokenizerFolder.appendingPathComponent(name)
                    if FileManager.default.fileExists(atPath: file.path) {
                        identity += name + "\0" + (try fingerprintFile(file)) + "\n"
                    }
                }
                tokenizerFingerprint = digest(Data(identity.utf8))
            }
        }
        for item in manifest.cases {
            guard !item.id.isEmpty, item.id.count <= 100, item.reference.count <= 16_000,
                  (item.finalReference?.count ?? 0) <= 16_000 else {
                throw EvaluationError.invalid("Case IDs must be 1–100 characters and references at most 16,000 characters.")
            }
            // Paths are relative to the manifest; absolute paths are permitted for local corpora.
            let audioURL = URL(fileURLWithPath: item.audio, relativeTo: manifestURL.deletingLastPathComponent()).standardizedFileURL
            do {
                let audio = try AVAudioFile(forReading: audioURL)
                let duration = Double(audio.length) / audio.processingFormat.sampleRate
                guard duration.isFinite, duration > 0, duration <= 121 else { throw EvaluationError.invalid("Audio must contain 0–121 seconds, matching Echo's recording scope.") }
                let loadStart = ProcessInfo.processInfo.systemUptime
                let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: audioURL.path, channelMode: .sumChannels(nil))
                let audioLoadSeconds = ProcessInfo.processInfo.systemUptime - loadStart
                guard !samples.isEmpty, samples.allSatisfy(\.isFinite) else { throw EvaluationError.invalid("Audio contains empty or non-finite samples.") }
                let audioFingerprint = try fingerprintFile(audioURL)
                let captured = CapturedAudio(generation: .init(rawValue: 1), samples: samples, convertedBufferCount: 1, droppedBufferCount: 0, finalizationTimedOut: false, finalizationDuration: 0, sampleRate: 16_000)
                if options.validateOnly {
                    let selected = trimmer.trim(captured)
                    rows.append(["id": item.id, "status": "validatedOnly", "audioSHA256": audioFingerprint,
                                 "recordedSeconds": captured.duration, "selectedSeconds": Double(selected.samples.count) / 16_000,
                                 "trimmingApplied": selected.trimmingApplied, "trimReason": selected.fallbackReason?.rawValue ?? "trimmed",
                                 "referenceWords": words(item.reference).count, "referenceCharacters": characters(item.reference).count])
                    continue
                }
                for repetition in 1...options.repetitions {
                    // Reverse budgets on alternating repetitions to reduce fixed-order bias.
                    let budgets = repetition.isMultiple(of: 2) ? options.promptBudgets.reversed().map { $0 } : options.promptBudgets
                    for budget in budgets {
                        for trim in options.trimModes {
                            let releaseStart = ProcessInfo.processInfo.systemUptime
                            let trimStart = ProcessInfo.processInfo.systemUptime
                            let selected = trim ? trimmer.trim(captured) : .fallback(captured, reason: .noReliableSpeech)
                            let trimSeconds = ProcessInfo.processInfo.systemUptime - trimStart
                            let asrStart = ProcessInfo.processInfo.systemUptime
                            let output = try await service.transcribe(selected.samples, request: .init(
                                vocabulary: vocabulary, language: options.language,
                                promptTokenBudget: budget, temperatureFallbackCount: options.fallbacks
                            ))
                            let asrSeconds = ProcessInfo.processInfo.systemUptime - asrStart
                            let processStart = ProcessInfo.processInfo.systemUptime
                            let finalText = processors.reduce(output.text) { $1.process($0) }
                            let processingSeconds = ProcessInfo.processInfo.systemUptime - processStart
                            let releaseSeconds = ProcessInfo.processInfo.systemUptime - releaseStart
                            let diagnostics = output.diagnostics
                            var row: [String: Any] = [
                                "id": item.id, "status": "transcribed", "repetition": repetition,
                                "firstReplayAfterLoad": replayIndex == 0, "engineState": "loadedAndWarmed",
                                "durationBucket": durationBucket(captured.duration),
                                "audioSHA256": audioFingerprint, "promptBudget": budget, "trimEnabled": trim,
                                "recordedSeconds": captured.duration, "selectedSeconds": Double(selected.samples.count) / 16_000,
                                "audioLoadSeconds": audioLoadSeconds, "trimSeconds": trimSeconds,
                                "asrSeconds": asrSeconds, "processingSeconds": processingSeconds, "releaseToResultSeconds": releaseSeconds,
                                "realTimeFactor": asrSeconds / captured.duration,
                                "trimmingApplied": selected.trimmingApplied, "trimReason": trim ? (selected.fallbackReason?.rawValue ?? "trimmed") : "disabled",
                                "leadingSamplesRemoved": selected.leadingSamplesRemoved, "trailingSamplesRemoved": selected.trailingSamplesRemoved,
                                "promptSeconds": diagnostics.promptDuration, "promptTokenCount": diagnostics.promptTokenCount,
                                "promptCacheHit": diagnostics.promptCacheHit, "inferenceSeconds": diagnostics.inferenceDuration, "decoderSeconds": diagnostics.decoderDuration,
                                "featureSeconds": diagnostics.featureDuration, "encoderSeconds": diagnostics.encoderDuration,
                                "encoderRuns": diagnostics.encoderRuns, "decoderTokenCount": diagnostics.decoderTokenCount,
                                "fallbackCountReported": diagnostics.fallbackCountReported,
                                "digitalSilence": diagnostics.isDigitalSilence, "needsReview": output.needsReview,
                                "rawWER": score(words(item.reference), words(output.text)),
                                "rawCER": score(characters(item.reference), characters(output.text)),
                                "falseInsertion": item.reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !output.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                "falseRejection": !item.reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && output.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                "rawCharacterCount": output.text.count, "finalCharacterCount": finalText.count
                            ]
                            if let language = output.language { row["detectedLanguage"] = language }
                            if let value = diagnostics.averageLogProbability, value.isFinite { row["averageLogProbability"] = value }
                            if let value = diagnostics.maximumCompressionRatio, value.isFinite { row["maximumCompressionRatio"] = value }
                            // Snippet expansion changes intended text; authors supply a separate
                            // final reference so a correct expansion is not scored as ASR error.
                            let finalReference = item.finalReference ?? item.reference
                            row["finalWER"] = score(words(finalReference), words(finalText))
                            row["finalCER"] = score(characters(finalReference), characters(finalText))
                            if options.includeText {
                                row["reference"] = item.reference
                                row["finalReference"] = finalReference
                                row["rawText"] = output.text
                                row["finalText"] = finalText
                            }
                            rows.append(row)
                            replayIndex += 1
                        }
                    }
                }
            } catch {
                failures += 1
                // The report stays content-free by default. Filesystem paths and library
                // error descriptions can contain private names; only stderr gets details.
                rows.append(["id": item.id, "status": "failed"])
                FileHandle.standardError.write(Data("Case \(item.id) failed: \(error.localizedDescription)\n".utf8))
            }
        }
        var report: [String: Any] = [
            "schema": 1, "mode": options.validateOnly ? "manifestValidation" : "audioReplay",
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "model": options.model, "language": options.language ?? "auto", "fallbackLimit": options.fallbacks,
            "whisperKitVersion": "0.18.0", "whisperKitRevision": "e2adabbe7d98dc4d0ab9a5b75424ecc42a9cdbef",
            "manifestSHA256": digest(manifestData), "executableSHA256": try fingerprintFile(Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])),
            "buildRevision": ProcessInfo.processInfo.environment["ECHO_BUILD_REVISION"] ?? "unrecorded",
            "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
            "processorCount": ProcessInfo.processInfo.processorCount, "physicalMemoryBytes": ProcessInfo.processInfo.physicalMemory,
            "preparationSeconds": preparationSeconds, "modelLoadAndWarmupSeconds": loadingSeconds,
            "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started,
            "includesText": options.includeText, "failedCases": failures,
            "normalization": "NFC, lowercase, punctuation becomes spaces; CER excludes whitespace; no-reference error rate is null",
            "fallbackCountCaveat": "WhisperKit 0.18 undercounts retries; reported values are not exact attempt counts.",
            "rows": rows, "summaries": summaries(rows)
        ]
        if let modelFingerprint { report["modelFilesSHA256"] = modelFingerprint }
        if let tokenizerFingerprint { report["tokenizerFilesSHA256"] = tokenizerFingerprint }
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        if let output = options.output { try data.write(to: output, options: .atomic) }
        else { FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8)) }
        if failures > 0 { throw EvaluationError.invalid("\(failures) case(s) failed; the report contains partial results.") }
    }

    private static func summaries(_ rows: [[String: Any]]) -> [[String: Any]] {
        let completed = rows.filter { $0["status"] as? String == "transcribed" }
        let groups = Dictionary(grouping: completed) { "\($0["promptBudget"] ?? 0)/\($0["trimEnabled"] ?? false)/\($0["durationBucket"] ?? "unknown")" }
        return groups.keys.sorted().map { key in
            let group = groups[key]!
            let latency = group.compactMap { $0["releaseToResultSeconds"] as? Double }.sorted()
            var summary: [String: Any] = ["promptBudget": group[0]["promptBudget"]!, "trimEnabled": group[0]["trimEnabled"]!, "durationBucket": group[0]["durationBucket"]!, "count": group.count,
                "releaseToResultP50Seconds": percentile(latency, 0.5), "releaseToResultP95Seconds": percentile(latency, 0.95),
                "falseInsertions": group.filter { $0["falseInsertion"] as? Bool == true }.count,
                "falseRejections": group.filter { $0["falseRejection"] as? Bool == true }.count]
            for metric in ["rawWER", "rawCER", "finalWER", "finalCER"] {
                let scores = group.compactMap { $0[metric] as? [String: Any] }
                let denominator = scores.reduce(0) { $0 + ($1["referenceUnits"] as? Int ?? 0) }
                let errors = scores.reduce(0) { $0 + ($1["editDistance"] as? Int ?? 0) }
                summary[metric] = ["referenceUnits": denominator, "editDistance": errors, "rate": denominator > 0 ? Double(errors) / Double(denominator) as Any : NSNull()]
            }
            return summary
        }
    }

    private static func durationBucket(_ seconds: Double) -> String {
        if seconds <= 1.2 { return "0-1.2s" }
        if seconds <= 8 { return "1.2-8s" }
        if seconds <= 30 { return "8-30s" }
        return "30-121s"
    }

    private static func percentile(_ sorted: [Double], _ quantile: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * quantile)) - 1))]
    }

    private static func normalized(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.lowercased().unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) || CharacterSet.nonBaseCharacters.contains($0) ? String($0) : " "
        }.joined()
    }
    private static func words(_ text: String) -> [String] { normalized(text).split(whereSeparator: \.isWhitespace).map(String.init) }
    private static func characters(_ text: String) -> [String] { normalized(text).filter { !$0.isWhitespace }.map(String.init) }
    private static func score(_ reference: [String], _ hypothesis: [String]) -> [String: Any] {
        let distance = editDistance(reference, hypothesis)
        return ["referenceUnits": reference.count, "hypothesisUnits": hypothesis.count, "editDistance": distance,
                "rate": reference.isEmpty ? NSNull() : Double(distance) / Double(reference.count) as Any]
    }
    private static func editDistance(_ left: [String], _ right: [String]) -> Int {
        // Two-row Levenshtein; identical prefixes/suffixes avoid expensive comparisons
        // for long literal snippets with only a small edited interior.
        var start = 0
        while start < min(left.count, right.count), left[start] == right[start] { start += 1 }
        var leftEnd = left.count, rightEnd = right.count
        while leftEnd > start, rightEnd > start, left[leftEnd - 1] == right[rightEnd - 1] { leftEnd -= 1; rightEnd -= 1 }
        let a = Array(left[start..<leftEnd]), b = Array(right[start..<rightEnd])
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for (i, source) in a.enumerated() {
            var current = [i + 1] + [Int](repeating: 0, count: b.count)
            for (j, target) in b.enumerated() {
                current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (source == target ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }

    private static func boundedRead(_ url: URL, maximumBytes: Int) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximumBytes else { throw EvaluationError.invalid("Manifest exceeds the 4 MB limit.") }
        return try Data(contentsOf: url)
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func fingerprintFile(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let block = try handle.read(upToCount: 1_024 * 1_024), !block.isEmpty { hasher.update(data: block) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func fingerprintDirectory(_ directory: URL) throws -> String {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { throw EvaluationError.invalid("Could not enumerate model assets.") }
        let files = try enumerator.compactMap { $0 as? URL }.filter {
            try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
                && $0.lastPathComponent != "echo-installation.json" && $0.lastPathComponent != ".DS_Store"
                && !$0.pathComponents.contains(".cache")
        }.sorted { $0.path < $1.path }
        var hasher = SHA256()
        for file in files {
            let relative = String(file.path.dropFirst(directory.path.count))
            hasher.update(data: Data((relative + "\0" + (try fingerprintFile(file)) + "\n").utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private struct Manifest: Decodable {
    struct Case: Decodable { let id: String; let audio: String; let reference: String; let finalReference: String? }
    struct Replacement: Decodable { let from: String; let to: String; let allowProtectedText: Bool? }
    struct SnippetRule: Decodable { let trigger: String; let expansion: String; let standaloneOnly: Bool?; let allowProtectedText: Bool? }
    let cases: [Case]
    let vocabulary: [String]?
    let replacements: [Replacement]?
    let snippets: [SnippetRule]?
}

private enum EvaluationError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}

private struct Options {
    var help = false
    var manifest: URL?
    var output: URL?
    var model = "distil-whisper_distil-large-v3_594MB"
    var downloadBase: URL?
    var download = false
    var validateOnly = false
    var includeText = false
    var repetitions = 1
    var promptBudgets = [200]
    var trimModes = [true]
    var language: String? = "en"
    var fallbacks = 5

    init(arguments: [String]) throws {
        var cursor = 0
        func url(_ value: String) -> URL { URL(fileURLWithPath: NSString(string: value).expandingTildeInPath).standardizedFileURL }
        while cursor < arguments.count {
            let flag = arguments[cursor]
            cursor += 1
            func value() throws -> String {
                guard cursor < arguments.count else { throw EvaluationError.invalid("Missing value for \(flag).") }
                defer { cursor += 1 }
                return arguments[cursor]
            }
            switch flag {
            case "--help", "-h": help = true
            case "--manifest": manifest = url(try value())
            case "--output": output = url(try value())
            case "--model": model = try value()
            case "--download-base": downloadBase = url(try value())
            case "--download": download = true
            case "--validate-only": validateOnly = true
            case "--include-text": includeText = true
            case "--repeat":
                guard let count = Int(try value()), (1...100).contains(count) else { throw EvaluationError.invalid("--repeat must be 1–100.") }
                repetitions = count
            case "--prompt-budgets":
                let parts = try value().split(separator: ",", omittingEmptySubsequences: false)
                let budgets = parts.compactMap { Int($0) }
                guard !budgets.isEmpty, parts.count == budgets.count, budgets.count <= 10, budgets.allSatisfy({ (0...200).contains($0) }) else { throw EvaluationError.invalid("--prompt-budgets requires 1–10 comma-separated integers from 0–200.") }
                promptBudgets = Array(Set(budgets)).sorted()
            case "--trim":
                switch try value() {
                case "on": trimModes = [true]
                case "off": trimModes = [false]
                case "both": trimModes = [false, true]
                default: throw EvaluationError.invalid("--trim must be on, off or both.")
                }
            case "--language":
                let selected = try value()
                language = selected == "auto" ? nil : selected
            case "--fallbacks":
                guard let count = Int(try value()), (0...5).contains(count) else { throw EvaluationError.invalid("--fallbacks must be 0–5.") }
                fallbacks = count
            default: throw EvaluationError.invalid("Unknown option \(flag). Use --help.")
            }
        }
        if !help, !validateOnly, WhisperModelCatalog.model(for: model) == nil { throw EvaluationError.invalid("Unknown model variant: \(model).") }
        if !help, !validateOnly, !WhisperModelCatalog.supportsMultilingual(model), language != "en" { throw EvaluationError.invalid("This model requires --language en.") }
    }

    static let usage = """
    EchoEvaluate — local fixed-model replay, using Echo's production pipeline.

    Usage: EchoEvaluate --manifest corpus.json [options]
      --model VARIANT          Existing catalog variant (default: Echo's Distil Large v3)
      --download-base PATH     Hugging Face cache root (default: Echo's cache location)
      --download               Explicitly allow model/tokenizer download or repair
      --repeat N               Repeat every clip 1–100 times (default: 1)
      --prompt-budgets 0,50,200 Compare token budgets with identical audio (default: 200)
      --trim on|off|both        Compare the production edge trimmer (default: on)
      --language en|auto|CODE   Auto/other languages require a multilingual catalog model
      --fallbacks 0..5         Decoder temperature fallback limit (default: 5)
      --output PATH            Write structured JSON (default: stdout)
      --include-text           Opt in to reference/raw/final text in local JSON
      --validate-only          Load audio and validate/trim fixtures without a speech model
      --help                   No model loading or download

    Manifest schema (audio paths relative to manifest):
    {"cases":[{"id":"clip-001","audio":"clip.wav","reference":"hello",
                "finalReference":"hello"}],
     "vocabulary":["Echo"], "replacements":[{"from":"eko","to":"Echo"}],
     "snippets":[{"trigger":"my signature","expansion":"Best, Alex",
                   "standaloneOnly":false,"allowProtectedText":false}]}

    Offline by default. No personal dictionaries/history are read. Audio, reference and
    output text are absent from JSON unless --include-text is supplied. Use anonymous IDs.
    WER uses whitespace-delimited words; CER is preferable for CJK. Rates for empty
    references are null; false-insertion counts cover silence/noise cases. Release-to-result
    timing excludes audio-file loading, model warm-up, scoring, hashing and paste delivery.
    """
}
