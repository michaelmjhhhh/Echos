import Foundation

struct VoiceActivityTrimmer: AudioTrimming {
    let configuration: CaptureConfiguration

    init(configuration: CaptureConfiguration = .default) {
        self.configuration = configuration
    }

    func trim(_ captured: CapturedAudio) -> TrimmedAudio {
        let samples = captured.samples
        let frameSize = configuration.analysisFrameSamples
        guard !samples.isEmpty, frameSize > 0 else {
            return .fallback(captured, reason: .emptyInput)
        }

        let energies = stride(from: 0, to: samples.count, by: frameSize).map { start -> Float in
            let end = min(start + frameSize, samples.count)
            var sum: Float = 0
            for sample in samples[start..<end] {
                sum += sample * sample
            }
            let rms = sqrt(sum / Float(end - start))
            return 20 * log10(max(rms, 0.000_000_1))
        }
        let sorted = energies.sorted()
        let noiseIndex = min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.2))
        let noiseFloor = sorted[noiseIndex]
        let startThreshold = max(
            configuration.startFloorDBFS,
            noiseFloor + configuration.startMarginDB
        )
        let continuationThreshold = max(
            configuration.continuationFloorDBFS,
            noiseFloor + configuration.continuationMarginDB
        )

        guard let firstSpeechFrame = onsetFrame(in: energies, threshold: startThreshold) else {
            return .fallback(captured, reason: .noReliableSpeech)
        }
        let lastActiveFrame = finalActiveFrame(
            in: energies,
            startingAt: firstSpeechFrame,
            threshold: continuationThreshold
        )

        let speechStart = firstSpeechFrame * frameSize
        let activeSpeechEnd = min(samples.count, (lastActiveFrame + 1) * frameSize)
        guard activeSpeechEnd - speechStart >= configuration.minimumSpeechSamples else {
            return .fallback(captured, reason: .speechTooShort)
        }

        let selectedStart = max(0, speechStart - configuration.paddingSamples)
        let hangoverSamples = configuration.hangoverFrames * frameSize
        let selectedEnd = min(
            samples.count,
            activeSpeechEnd + hangoverSamples + configuration.paddingSamples
        )
        let removed = samples.count - (selectedEnd - selectedStart)
        guard Double(removed) / Double(samples.count) <= configuration.maximumTrimRatio else {
            return .fallback(captured, reason: .excessiveTrim)
        }
        guard selectedStart > 0 || selectedEnd < samples.count else {
            return .fallback(captured, reason: .noReliableSpeech)
        }

        let range = selectedStart..<selectedEnd
        return TrimmedAudio(
            samples: Array(samples[range]),
            selectedRange: range,
            leadingSamplesRemoved: selectedStart,
            trailingSamplesRemoved: samples.count - selectedEnd,
            trimmingApplied: true,
            fallbackReason: nil
        )
    }

    private func onsetFrame(in energies: [Float], threshold: Float) -> Int? {
        var run = 0
        for (index, energy) in energies.enumerated() {
            run = energy >= threshold ? run + 1 : 0
            if run == configuration.onsetFrameCount {
                return index - configuration.onsetFrameCount + 1
            }
        }
        return nil
    }

    private func finalActiveFrame(
        in energies: [Float],
        startingAt first: Int,
        threshold: Float
    ) -> Int {
        var lastActive = first
        for index in first..<energies.count where energies[index] >= threshold {
            lastActive = index
        }
        return lastActive
    }
}
