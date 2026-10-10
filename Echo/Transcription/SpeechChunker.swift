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
    /// Cut points are searched within four seconds of the even split point.
    static let searchSamples = 8 * sampleRate
    static let frameSamples = 320
    /// A 200 ms window finds a pause between words rather than a stop consonant.
    static let pauseFrames = 10

    /// Chunks are kept near equal length, so a 29-second recording becomes two
    /// ~14-second chunks rather than 28 s plus a 1-second tail. A short chunk
    /// decoded with only the previous chunk's text as its prompt can come back
    /// empty or as a caption such as "Thank you." Every chunk is at least ~10 s.
    static func chunks(_ samples: [Float]) -> [Range<Int>] {
        guard samples.count > maximumChunkSamples else { return [samples.indices] }
        var ranges: [Range<Int>] = []
        var start = 0
        while samples.count - start > maximumChunkSamples {
            let remaining = samples.count - start
            let count = (remaining + maximumChunkSamples - 1) / maximumChunkSamples
            // Search around the even split point, but never so early that the
            // rest no longer fits in the remaining chunks.
            let end = start + min(maximumChunkSamples, remaining / count + searchSamples / 2)
            let lower = max(end - searchSamples, samples.count - (count - 1) * maximumChunkSamples)
            let cut = quietestPoint(in: samples, range: lower..<end)
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
            samples[start..<(start + frameSamples)].reduce(Float(0)) { $0 + $1 * $1 }
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
