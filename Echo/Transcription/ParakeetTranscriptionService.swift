import Foundation
import FluidAudio

/// Whisper pads every recording to a 30-second window, so its encoder costs
/// the same for one word as for a paragraph. Parakeet's encoder is far cheaper
/// per window on the Neural Engine, which removes most of that fixed wait.
/// Parakeet takes no text prompt: dictionary hints, recent context and
/// temperature retries do not apply. Saved spelling corrections still do.
final class ParakeetTranscriptionService: Transcribing {
    private let downloadBase: URL?
    private(set) var modelFolder: URL?
    private var manager: AsrManager?
    private let gate = TranscriptionGate()
    /// Below FluidAudio's 15-second single-pass limit, with margin.
    static let maximumChunkSamples = 14 * SpeechChunker.sampleRate
    /// Parakeet has no prompt to carry, so short final chunks are acceptable.
    static let minimumChunkSamples = 4 * SpeechChunker.sampleRate

    init(downloadBase: URL? = nil) {
        self.downloadBase = downloadBase
    }

    func prepare(forceRepair: Bool, progress: @escaping (Double) -> Void) async throws {
        modelFolder = try await ModelAcquisition.shared.prepare(
            variant: ParakeetModelPaths.variant, downloadBase: downloadBase, forceRepair: forceRepair, progress: progress
        )
        try Task.checkCancellation()
    }

    /// Evaluation/offline entry point: never downloads.
    func prepareInstalled() async throws {
        let folder = ParakeetModelPaths.folder(downloadBase: downloadBase)
        guard ParakeetModelPaths.isInstalled(at: folder) else {
            throw ModelInstallationError.invalidAssets("Parakeet model files")
        }
        modelFolder = folder
    }

    func loadModel() async throws {
        try await gate.acquire()
        do {
            try Task.checkCancellation()
            guard let modelFolder, ParakeetModelPaths.isInstalled(at: modelFolder) else {
                throw TranscriptionError.modelNotPrepared
            }
            let models = try await AsrModels.load(from: modelFolder, version: ParakeetModelPaths.version)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            try Task.checkCancellation()
            // The first inference prepares the Neural Engine. Pay it at startup,
            // not on the first dictation. The output is discarded.
            _ = try await Self.decode(Self.padded([]), with: manager)
            try Task.checkCancellation()
            self.manager = manager
            await gate.release()
        } catch {
            manager = nil
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
        guard let manager else { throw TranscriptionError.modelNotLoaded }
        guard !samples.isEmpty, samples.allSatisfy(\.isFinite) else { throw TranscriptionError.invalidAudio }
        var diagnostics = TranscriptionDiagnostics()
        diagnostics.recordedDuration = Double(samples.count) / 16_000
        if samples.allSatisfy({ $0 == 0 }) {
            diagnostics.isDigitalSilence = true
            return TranscriptionOutput(text: "", diagnostics: diagnostics)
        }
        if let language = request.language, language != "en" { throw TranscriptionError.unsupportedLanguage }
        let start = ProcessInfo.processInfo.systemUptime
        var texts: [String] = []
        // FluidAudio splits audio over 15 s into overlapping windows and drops
        // tokens it sees twice in the overlap. In replay that lost a repeated
        // "yes" from a 60-second clip. Cutting at pauses into single-window
        // chunks keeps every chunk on the one-pass path.
        for range in SpeechChunker.chunks(samples, maximumSamples: Self.maximumChunkSamples,
                                          minimumSamples: Self.minimumChunkSamples) {
            let result = try await Self.decode(Self.padded(Array(samples[range])), with: manager)
            try Task.checkCancellation()
            diagnostics.encoderRuns += 1
            diagnostics.decoderTokenCount += result.tokenTimings?.count ?? 0
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { texts.append(text) }
        }
        diagnostics.inferenceDuration = ProcessInfo.processInfo.systemUptime - start
        return TranscriptionOutput(text: texts.joined(separator: " "), language: "en", diagnostics: diagnostics)
    }

    private static func decode(_ samples: [Float], with manager: AsrManager) async throws -> ASRResult {
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        return try await manager.transcribe(samples, decoderState: &state)
    }

    /// FluidAudio rejects audio under its minimum length. Echo accepts
    /// recordings from 0.3 s, so short clips get trailing silence.
    private static func padded(_ samples: [Float]) -> [Float] {
        let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: 16_000)
        guard samples.count < minimum else { return samples }
        return samples + [Float](repeating: 0, count: minimum - samples.count)
    }
}
