import Foundation
import WhisperKit
import Tokenizers

protocol Transcribing {
    func prepare(progress: @escaping (Double) -> Void) async throws
    func prepare(forceRepair: Bool, progress: @escaping (Double) -> Void) async throws
    func loadModel() async throws
    func transcribe(_ samples: [Float], vocabulary: [String]) async throws -> String
    func transcribe(_ samples: [Float], request: TranscriptionRequest) async throws -> TranscriptionOutput
}

extension Transcribing {
    func prepare(forceRepair: Bool, progress: @escaping (Double) -> Void) async throws {
        try await prepare(progress: progress)
    }

    func transcribe(_ samples: [Float], request: TranscriptionRequest) async throws -> TranscriptionOutput {
        TranscriptionOutput(text: try await transcribe(samples, vocabulary: request.vocabulary), language: request.language)
    }
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

    init(modelVariant: String, downloadBase: URL? = nil) {
        self.modelVariant = modelVariant
        self.downloadBase = downloadBase
    }

    func prepare(progress: @escaping (Double) -> Void) async throws {
        try await prepare(forceRepair: false, progress: progress)
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
            kit.tokenizer = try LocalWhisperTokenizer(tokenizer: tokenizer)
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
            await gate.release()
        } catch {
            whisperKit = nil
            await gate.release()
            throw error
        }
    }

    func transcribe(_ samples: [Float], vocabulary: [String]) async throws -> String {
        try await transcribe(samples, request: TranscriptionRequest(vocabulary: vocabulary, language: "en")).text
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
            windowClipTime: 1, concurrentWorkerCount: 1
        )
        let promptStart = ProcessInfo.processInfo.systemUptime
        let key = PromptKey(vocabulary: request.vocabulary, language: language, budget: min(200, max(0, request.promptTokenBudget)))
        let tokens: [Int]
        if let cached = promptCache, cached.key == key {
            tokens = cached.tokens
            diagnostics.promptCacheHit = true
        } else if key.budget > 0, let tokenizer = whisperKit.tokenizer {
            let words = request.vocabulary.map { $0.precomposedStringWithCanonicalMapping }
            let prompt = VocabularyPrompt.text(for: words, maxTokens: key.budget) {
                tokenizer.encode(text: " " + $0).count
            }
            tokens = prompt.isEmpty ? [] : tokenizer.encode(text: " " + prompt).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            promptCache = (key, tokens)
        } else {
            tokens = []
            promptCache = (key, tokens)
        }
        diagnostics.promptDuration = ProcessInfo.processInfo.systemUptime - promptStart
        diagnostics.promptTokenCount = tokens.count
        options.promptTokens = tokens.isEmpty ? nil : tokens
        var input = samples
        input.append(contentsOf: repeatElement(0, count: Int(options.windowClipTime * 16_000)))
        let decodeStart = ProcessInfo.processInfo.systemUptime
        let results = try await whisperKit.transcribe(audioArray: input, decodeOptions: options)
        try Task.checkCancellation()
        diagnostics.inferenceDuration = ProcessInfo.processInfo.systemUptime - decodeStart
        let segments = results.flatMap(\.segments).map {
            TranscriptionSegmentInfo(text: $0.text, start: Double($0.start), end: Double($0.end), averageLogProbability: $0.avgLogprob, compressionRatio: $0.compressionRatio)
        }
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
            diagnostics.averageLogProbability = segments.map(\.averageLogProbability).reduce(0, +) / Float(segments.count)
            diagnostics.maximumCompressionRatio = segments.map(\.compressionRatio).max()
        }
        // Flag supported warning signals for recoverable review. Never delete
        // plausible quiet speech based on these uncalibrated numbers.
        let needsReview = segments.contains { $0.averageLogProbability < -1 || $0.compressionRatio > 2.4 }
        return TranscriptionOutput(
            text: results.map(\.text).joined(separator: " "), language: results.first?.language ?? language,
            segments: segments, diagnostics: diagnostics, needsReview: needsReview
        )
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
