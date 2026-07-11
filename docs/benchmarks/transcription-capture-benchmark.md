# Transcription Capture Benchmark

## Variants

1. Baseline commit immediately before capture optimization.
2. Deterministic finalization with trimming disabled by an identity trimmer.
3. Deterministic finalization with the default `VoiceActivityTrimmer`.

## Devices

- Built-in microphone
- One Bluetooth microphone
- One USB microphone

## Local corpus

Use the same locally held, labeled utterances for every variant/device pair:

- 20 short utterances (0.5–2 seconds)
- 20 normal utterances (3–8 seconds)
- 20 pause-heavy utterances
- 20 quiet utterances
- 20 noisy utterances
- 10 utterances emphasizing first and last plosives

The corpus and reference transcripts remain local and are never committed.

## Measurements

Export aggregate values only:

- WER and CER
- First-word and last-word omission rates
- p50, p90, p95, and p99 finalization duration
- p50, p90, p95, and p99 transcription duration
- p50, p90, p95, and p99 release-to-result latency
- Selected/raw duration ratio
- Conversion-drop count
- Finalization-timeout count

## Procedure

1. Restart Echo before each variant to normalize model warm-up.
2. Perform one unmeasured warm-up dictation.
3. Run every corpus item once per device and variant.
4. Keep the model variant, room, input gain, and microphone placement fixed.
5. Calculate aggregate metrics without retaining captured audio or recognized text in Echo's usage database.
6. Investigate every finalization timeout and every new first/last-word omission before release.

## Release gates

- Overall WER and CER do not exceed baseline.
- First-word and last-word omission rates do not exceed baseline.
- Silence-heavy p95 release-to-result latency is lower than baseline.
- Automated tests show no cross-generation contamination.
- Normal finalization completes within one conversion cycle, with no unexplained timeout.

Device results must be recorded before claiming real-world accuracy or latency improvement. An unrun device matrix remains an explicit release risk.
