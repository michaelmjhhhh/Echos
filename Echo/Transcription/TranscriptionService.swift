import Foundation
import WhisperKit
import Tokenizers

protocol Transcribing {
    func prepare(forceRepair: Bool, progress: @escaping (Double) -> Void) async throws
    func loadModel() async throws
    func transcribe(_ samples: [Float], request: TranscriptionRequest) async throws -> TranscriptionOutput
}

/// One service owns one engine. The gate remains occupied until a cancelled
/// inference actually exits, so a late CoreML operation cannot overlap another.
final class TranscriptionService: Transcribing {
    private let modelVariant: String
    private let downloadBase: URL?
    private(set) var modelFolder: URL?
    private var whisperKit: WhisperKit?
    private var tokenizerFolder: URL?
    private let gate = TranscriptionGate()
    private struct PromptKey: Equatable {
        let vocabulary: [String]
        let language: String?
        let budget: Int
    }
    private var promptCache: (key: PromptKey, tokens: [Int])?
    private var nonSpeechTokens: [Int] = []
    /// Recent text goes last in the prompt, where Whisper reads it as the
    /// preceding speech. A short suffix is enough to carry names and casing.
    static let contextTokenLimit = 48

    init(modelVariant: String, downloadBase: URL? = nil) {
        self.modelVariant = modelVariant
        self.downloadBase = downloadBase
    }

    func prepare(forceRepair: Bool, progress: @escaping (Double) -> Void) async throws {
        modelFolder = try await ModelAcquisition.shared.prepare(
            variant: modelVariant, downloadBase: downloadBase, forceRepair: forceRepair, progress: progress
        )
        tokenizerFolder = modelFolder
        try Task.checkCancellation()
    }

    /// Evaluation/offline entry point: never invokes model acquisition or any
    /// downloader, including when installed tokenizer data is damaged.
    func prepareInstalled() async throws {
        let folder = WhisperModelPaths.modelFolder(for: modelVariant, downloadBase: downloadBase)
        try WhisperModelPaths.validateModel(at: folder)
        guard let tokenizerLocation = WhisperModelPaths.localTokenizerFolder(for: modelVariant, downloadBase: downloadBase) else {
            throw ModelInstallationError.invalidAssets("tokenizer")
        }
        _ = try LocalWhisperTokenizer(tokenizer: await AutoTokenizer.from(modelFolder: tokenizerLocation))
        try Task.checkCancellation()
        modelFolder = folder
        tokenizerFolder = tokenizerLocation
    }

    func loadModel() async throws {
        try await gate.acquire()
        do {
            try Task.checkCancellation()
            guard let modelFolder else { throw TranscriptionError.modelNotPrepared }
            try WhisperModelPaths.validateModel(at: modelFolder)
            // This overload only reads local files. Inject before loadModels so
            // WhisperKit cannot silently fall back to a network tokenizer fetch.
            let tokenizer = try await AutoTokenizer.from(modelFolder: tokenizerFolder ?? modelFolder)
            let kit = try await WhisperKit(WhisperKitConfig(
                model: modelVariant,
                modelFolder: modelFolder.path,
                tokenizerFolder: modelFolder,
                verbose: false,
                prewarm: true,
                load: false,
                download: false
            ))
            let whisperTokenizer = try LocalWhisperTokenizer(tokenizer: tokenizer)
            kit.tokenizer = whisperTokenizer
            try await kit.loadModels()
            if let logitsSize = kit.textDecoder.logitsSize {
                (kit.textDecoder as? TextDecoder)?.isModelMultilingual = logitsSize != 51_864
            }
            try Task.checkCancellation()
            // More than the one-second seek guard, with bounded decoding work.
            // The throwaway output is never inserted, saved, or treated as speech.
            let options = DecodingOptions(
                task: .transcribe, language: "en", temperatureFallbackCount: 0,
                sampleLength: 8, skipSpecialTokens: true, windowClipTime: 1,
                concurrentWorkerCount: 1
            )
            let warmup = try await kit.transcribe(audioArray: [Float](repeating: 0, count: 19_200), decodeOptions: options)
            guard warmup.contains(where: { $0.timings.totalEncodingRuns > 0 }) else {
                throw TranscriptionError.warmupFailed
            }
            try Task.checkCancellation()
            whisperKit = kit
            promptCache = nil
            nonSpeechTokens = Self.nonSpeechTokens(whisperTokenizer)
            await gate.release()
        } catch {
            whisperKit = nil
            await gate.release()
            throw error
        }
    }

    func transcribe(_ samples: [Float], request: TranscriptionRequest) async throws -> TranscriptionOutput {
        try await gate.acquire()
        do {
            let result = try await transcribeExclusively(samples, request: request)
            await gate.release()
            return result
        } catch {
            await gate.release()
            throw error
        }
    }

    private func transcribeExclusively(_ samples: [Float], request: TranscriptionRequest) async throws -> TranscriptionOutput {
        try Task.checkCancellation()
        guard let whisperKit else { throw TranscriptionError.modelNotLoaded }
        guard !samples.isEmpty, samples.allSatisfy(\.isFinite) else { throw TranscriptionError.invalidAudio }
        var diagnostics = TranscriptionDiagnostics()
        diagnostics.recordedDuration = Double(samples.count) / 16_000
        // Only exact digital silence is rejected. Amplitude thresholds can
        // mistake quiet speech for silence; ambiguous audio always reaches ASR.
        if samples.allSatisfy({ $0 == 0 }) {
            diagnostics.isDigitalSilence = true
            return TranscriptionOutput(text: "", diagnostics: diagnostics)
        }
        let multilingual = WhisperModelCatalog.supportsMultilingual(modelVariant)
        if !multilingual, let language = request.language, language != "en" {
            throw TranscriptionError.unsupportedLanguage
        }
        let language = multilingual ? request.language : "en"
        var options = DecodingOptions(
            task: .transcribe, language: language,
            temperature: 0, temperatureIncrementOnFallback: 0.2,
            temperatureFallbackCount: min(5, max(0, request.temperatureFallbackCount)),
            usePrefillPrompt: true, usePrefillCache: true,
            detectLanguage: multilingual && language == nil, skipSpecialTokens: true,
            // Preserve WhisperKit's one-second synthetic-tail safeguard. The
            // adapter appends that second below so real final words are eligible
            // even when they fall just after a 30-second window boundary.
            windowClipTime: 1,
            // WhisperKit 0.18 suppresses no tokens by default. suppressBlank is
            // left off: its filter compares against the prefill cache length and
            // never fires once the prompt tokens are in the token list.
            supressTokens: nonSpeechTokens,
            concurrentWorkerCount: 1
        )
        let chunks = SpeechChunker.chunks(samples)
        let promptStart = ProcessInfo.processInfo.systemUptime
        // Later chunks always receive the previous chunk as context, so long
        // recordings reserve its share of the prompt from the first chunk on.
        let reservesContext = !request.context.isEmpty || chunks.count > 1
        // WhisperKit drops the start of a longer prompt, which holds the starred words.
        let limit = VocabularyPrompt.promptTokenLimit - (reservesContext ? Self.contextTokenLimit : 0)
        let glossary = glossaryTokens(
            for: request.vocabulary, language: language,
            budget: min(limit, max(0, request.promptTokenBudget)),
            tokenizer: whisperKit.tokenizer, diagnostics: &diagnostics
        )
        diagnostics.promptDuration = ProcessInfo.processInfo.systemUptime - promptStart
        var context = request.context
        var results: [TranscriptionResult] = []
        let decodeStart = ProcessInfo.processInfo.systemUptime
        for range in chunks {
            let promptStart = ProcessInfo.processInfo.systemUptime
            let tokens = glossary + contextTokens(for: context, tokenizer: whisperKit.tokenizer)
            diagnostics.promptDuration += ProcessInfo.processInfo.systemUptime - promptStart
            diagnostics.promptTokenCount = max(diagnostics.promptTokenCount, tokens.count)
            options.promptTokens = tokens.isEmpty ? nil : tokens
            var input = Array(samples[range])
            input.append(contentsOf: repeatElement(0, count: Int(options.windowClipTime * 16_000)))
            let chunkResults = try await whisperKit.transcribe(audioArray: input, decodeOptions: options)
            try Task.checkCancellation()
            results += chunkResults
            let text = chunkResults.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { context = String((context + " " + text).suffix(1_000)) }
        }
        diagnostics.inferenceDuration = ProcessInfo.processInfo.systemUptime - decodeStart
        let segments = results.flatMap(\.segments)
        for result in results {
            diagnostics.encoderRuns += Int(result.timings.totalEncodingRuns)
            diagnostics.decoderTokenCount += Int(result.timings.totalDecodingLoops)
            diagnostics.fallbackCountReported += Int(result.timings.totalDecodingFallbacks)
            // In 0.18 decodingLoop is overwritten with the entire window loop
            // (including feature extraction and encoding). Sum decoder-only
            // components; filtering/sampling/KV time is inside nonPrediction.
            diagnostics.decoderDuration += result.timings.decodingInit + result.timings.prefill
                + result.timings.decodingPredictions + result.timings.decodingNonPrediction
            diagnostics.featureDuration += result.timings.logmels
            diagnostics.encoderDuration += result.timings.encoding
        }
        if !segments.isEmpty {
            diagnostics.averageLogProbability = segments.map(\.avgLogprob).reduce(0, +) / Float(segments.count)
            diagnostics.maximumCompressionRatio = segments.map(\.compressionRatio).max()
        }
        // Flag supported warning signals for recoverable review. Never delete
        // plausible quiet speech based on these uncalibrated numbers.
        let needsReview = segments.contains { $0.avgLogprob < -1 || $0.compressionRatio > 2.4 }
        return TranscriptionOutput(
            text: results.map(\.text).joined(separator: " "), language: results.first?.language ?? language,
            diagnostics: diagnostics, needsReview: needsReview
        )
    }

    /// Dictionary words keep their priority order and stay whole; the result is
    /// cached because the vocabulary rarely changes between dictations.
    private func glossaryTokens(for vocabulary: [String], language: String?, budget: Int,
                                tokenizer: WhisperTokenizer?, diagnostics: inout TranscriptionDiagnostics) -> [Int] {
        let key = PromptKey(vocabulary: vocabulary, language: language, budget: budget)
        if let cached = promptCache, cached.key == key {
            diagnostics.promptCacheHit = true
            return cached.tokens
        }
        var tokens: [Int] = []
        if budget > 0, let tokenizer {
            let words = vocabulary.map { $0.precomposedStringWithCanonicalMapping }
            let prompt = VocabularyPrompt.text(for: words, maxTokens: budget) {
                tokenizer.encode(text: " " + $0).count
            }
            tokens = prompt.isEmpty ? [] : tokenizer.encode(text: " " + prompt).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        }
        promptCache = (key, tokens)
        return tokens
    }

    private func contextTokens(for context: String, tokenizer: WhisperTokenizer?) -> [Int] {
        let text = context.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let tokenizer else { return [] }
        let tokens = tokenizer.encode(text: " " + text).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        return Array(tokens.suffix(Self.contextTokenLimit))
    }

    /// Whisper captions sound events as "(music)", "[BLANK_AUDIO]", "*sigh*" or "♪".
    /// Suppress the single tokens that open them, a subset of OpenAI's default
    /// suppress list. Punctuation people dictate (colon, slash, @, #) stays allowed.
    private static func nonSpeechTokens(_ tokenizer: WhisperTokenizer) -> [Int] {
        let symbols = ["(", "[", "{", "*", "((", "[[", "{{", "(((", "-(", "-[", "('", "(\"", "♪", "♪♪", "♪♪♪", "♩", "♫", "♬"]
        var tokens = Set<Int>()
        for symbol in symbols {
            for text in [symbol, " " + symbol] {
                let encoded = tokenizer.encode(text: text).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
                if encoded.count == 1 { tokens.insert(encoded[0]) }
            }
        }
        return tokens.sorted()
    }
}

private actor TranscriptionGate {
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async throws {
        if occupied { await withCheckedContinuation { waiters.append($0) } } else { occupied = true }
        // A cancelled waiter must hand the lease on before exiting.
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    func release() {
        if waiters.isEmpty { occupied = false } else { waiters.removeFirst().resume() }
    }
}

enum TranscriptionError: LocalizedError {
    case modelNotLoaded, modelNotPrepared, invalidAudio, unsupportedLanguage, warmupFailed
    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: return "The speech model is not loaded yet."
        case .modelNotPrepared: return "Download or repair the speech model before loading it."
        case .invalidAudio: return "The microphone returned empty or invalid audio. Try recording again."
        case .unsupportedLanguage: return "This model supports English dictation only."
        case .warmupFailed: return "The speech model did not complete its startup check. Retry setup or repair the model."
        }
    }
}
