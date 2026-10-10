import Foundation

/// Splits recordings longer than one Whisper window at the quietest pause so
/// each chunk decodes in a single 30-second window. WhisperKit 0.18 does not
/// carry text between its own windows; decoding chunks in order lets the
/// service pass each chunk's text to the next one as prompt context.
enum SpeechChunker {
    static let sampleRate = 16_000
    /// The service appends a one-second tail, so 28 s keeps every chunk
    /// inside one 30-second window with margin.
    static let maximumChunkSamples = 28 * sampleRate
    /// Cut points are searched in the final eight seconds of each chunk.
    static let searchSamples = 8 * sampleRate
    /// A short final chunk decoded with only the previous chunk's text as its
    /// prompt can come back empty or as a caption such as "Thank you."
    static let minimumChunkSamples = 10 * sampleRate
    static let frameSamples = 320
    /// A 200 ms window finds a pause between words rather than a stop consonant.
    static let pauseFrames = 10

    /// Chunks are cut near 28 s, the length measured in replay. When that
    /// would leave a final chunk under 10 s, the last two chunks are split
    /// about evenly instead (each 10 s or longer) rather than 28 s plus a
    /// 1-second tail for a 29-second recording.
    static func chunks(_ samples: [Float]) -> [Range<Int>] {
        guard samples.count > maximumChunkSamples else { return [samples.indices] }
        var ranges: [Range<Int>] = []
        var start = 0
        while samples.count - start > maximumChunkSamples {
            let remaining = samples.count - start
            let length = remaining < maximumChunkSamples + minimumChunkSamples
                ? remaining / 2 + searchSamples / 2
                : maximumChunkSamples
            let end = start + min(maximumChunkSamples, length)
            let cut = quietestPoint(in: samples, range: (end - searchSamples)..<end)
            ranges.append(start..<cut)
            start = cut
        }
        ranges.append(start..<samples.count)
        return ranges
    }

    /// Returns the centre of the lowest-energy 200 ms span. Ties prefer the
    /// later span so chunks stay long.
    private static func quietestPoint(in samples: [Float], range: Range<Int>) -> Int {
        let energies = stride(from: range.lowerBound, to: range.upperBound - frameSamples + 1, by: frameSamples).map { start in
            samples[start..<(start + frameSamples)].reduce(0.0) { $0 + Double($1 * $1) }
        }
        guard energies.count > pauseFrames else { return range.upperBound }
        var sum = energies[0..<pauseFrames].reduce(0, +)
        var best = (sum: sum, frame: 0)
        for frame in 1...(energies.count - pauseFrames) {
            sum += energies[frame + pauseFrames - 1] - energies[frame - 1]
            if sum <= best.sum { best = (sum, frame) }
        }
        return range.lowerBound + (best.frame + pauseFrames / 2) * frameSamples
    }
}
