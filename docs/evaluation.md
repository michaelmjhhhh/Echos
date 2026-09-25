# Reproducible builds and local replay

EchoEvaluate replays explicitly supplied local audio through the same transcription service, edge trimmer, dictionary replacement and snippet processors as Echo. It does not read microphone recordings, app history, personal dictionaries or user defaults. Model weights stay unchanged within a comparison.

Builds use Xcode 26.5, macOS 14 or later, Apple Silicon and XcodeGen 2.45.3 or later. CI selects Xcode 26.5 explicitly on the `macos-26` runner. The [current runner inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md) lists that installation. The app still deploys to macOS 14.

## Dependency identity

`project.yml` requires Argmax/WhisperKit **0.18.0**, revision `e2adabbe7d98dc4d0ab9a5b75424ecc42a9cdbef`. `config/Package.resolved` tracks every transitive package revision. XcodeGen's documented [`postGenCommand`](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md#options) restores that lock into the otherwise ignored generated project. Both CI and release builds use only the resolved versions, then verify that no pin changed.

```sh
xcodegen generate
xcodebuild -project Echo.xcodeproj -scheme EchoEvaluate \
  -resolvePackageDependencies -clonedSourcePackagesDirPath build/SourcePackages \
  -onlyUsePackageVersionsFromResolvedFile
python3 scripts/verify-package-lock.py
xcodebuild -project Echo.xcodeproj -scheme EchoEvaluate -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/evaluate \
  -clonedSourcePackagesDirPath build/SourcePackages \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  ARCHS=arm64 CODE_SIGNING_ALLOWED=NO build
build/evaluate/Build/Products/Release/EchoEvaluate --help
```

When updating dependencies intentionally, review the generated lock against `config/Package.resolved`, copy the reviewed lock back, and re-run validation. Do not rely on an ignored generated lock to pin a release. A changed lock origin hash alone is not a dependency revision change; verification compares every pin and location.

## Corpus format

Use a JSON manifest. Audio paths are relative to the manifest or absolute local paths. Supported input formats are those AVFoundation/WhisperKit can decode. Files are converted to mono 16 kHz, and input is bounded to 121 seconds to match the app's recording scope.

```json
{
  "cases": [
    {"id": "clip-001", "audio": "short.wav", "reference": "Yes."},
    {"id": "clip-002", "audio": "signature.wav", "reference": "my signature", "finalReference": "Best, Alex"},
    {"id": "clip-003", "audio": "silence.wav", "reference": ""}
  ],
  "vocabulary": ["Kubernetes", "Echo"],
  "replacements": [{"from": "eko", "to": "Echo"}],
  "snippets": [{"trigger": "my signature", "expansion": "Best, Alex", "standaloneOnly": true}]
}
```

`finalReference` is optional and defaults to `reference`. Supply it when a snippet or deliberate correction changes the intended final text. Otherwise a correct expansion would appear to harm recognition accuracy. Rule entries may explicitly set `allowProtectedText: true`; default URL, email and code protections match the app. The manifest rejects duplicate normalized aliases/triggers.

Keep actual recordings and references outside the repository. Use anonymous case IDs. Outputs contain IDs, hashes, counts, errors and timing by default; `--include-text` explicitly includes local reference/raw/final text. Error details go to stderr and can contain filesystem paths, so keep logs local too.

## Paired replay

```sh
ECHO_BUILD_REVISION="$(git rev-parse HEAD)" \
  build/evaluate/Build/Products/Release/EchoEvaluate \
  --manifest /path/to/corpus/manifest.json \
  --model distil-whisper_distil-large-v3_594MB \
  --repeat 5 --prompt-budgets 0,25,50,100,200 --trim both \
  --language en --output /path/to/results.json
```

Replay is **offline by default**. It validates and loads installed model/tokenizer files through `prepareInstalled()`, including the supported legacy local tokenizer cache. Missing or damaged assets fail with an error; they do not trigger a download. Use `--download` only when intentionally acquiring assets. `--download-base` chooses an isolated Hugging Face cache root. `--language auto` or another supported language requires a multilingual catalog artifact; English-only models require `en`.

Each run records the actual model-file and tokenizer-file SHA-256 identities, manifest and executable hashes, OS, CPU count, memory, dependency revision and selected decoder policy. Model hashing occurs once outside measured replay stages. Comparing reports with different asset hashes is a different-model comparison. Asset downloads are not pinned to a Hugging Face commit by this adapter; retain the installed artifacts and compare hashes when repeating a baseline.

`--fallbacks 0..5` permits explicit decoder experiments; the production default remains 5. Budgets are reversed on alternating repetitions to reduce fixed-order effects. This is not a randomized benchmark: vary run order and repeat cold launches independently when making performance decisions.

## Reading the report

- Raw WER is word edit distance divided by reference words. Raw CER uses characters instead. Final WER/CER use the explicit final reference and post-processing result. Normalization uses NFC, lowercase, punctuation as spaces, and removes whitespace for CER. CER is preferable for CJK; whitespace-based WER is not a language-aware CJK tokenizer.
- Empty-reference error rates are `null`. False-insertion and false-rejection counts describe no-speech and missing-output cases separately. A known-silence clip is not scored as zero WER merely because its reference denominator is zero.
- `releaseToResultSeconds` measures trimming, transcription and text processing using a monotonic clock. It excludes file conversion, model preparation/warm-up, hashing, scoring, clipboard work and visible paste delivery. It must not be advertised as release-to-visible-text latency.
- `asrSeconds` is the service call's wall time. Prompt preparation, full inference, feature extraction, encoder and decoder durations are reported separately. Dependency counters are diagnostic signals; `fallbackCountReported` is explicitly not an exact retry count because WhisperKit 0.18 undercounts and overwrites some retry values.
- Summaries group by prompt budget, trim mode and original duration bucket, and report p50/p95 using nearest-rank percentiles. Review sample counts before interpreting p95. Every replay follows production model load and warm-up; `modelLoadAndWarmupSeconds` is reported separately and `firstReplayAfterLoad` identifies the first replay. Cold-start behavior requires fresh process runs.
- A case failure writes a partial report and exits nonzero. Partial results never imply a fully successful run. `--validate-only` reports audio/schema/trim validation without ASR metrics and never loads a model.

Use the [capture benchmark protocol](benchmarks/transcription-capture-benchmark.md) and the [review scenario matrix](reviews/2026-09-25-codebase-review.md) for microphone onset/tail, Bluetooth, target/clipboard and lifecycle checks. File replay does not exercise those hardware and desktop paths. Synthetic speech is a smoke fixture, not evidence of real microphone accuracy.

## Owned fixtures and validation gate

```sh
python3 scripts/make-evaluation-fixtures.py --output /tmp/echo-fixtures --speech
build/evaluate/Build/Products/Release/EchoEvaluate \
  --manifest /tmp/echo-fixtures/manifest.json --validate-only \
  --output /tmp/echo-fixtures/validation.json
```

The generator creates deterministic 0.3/0.5/0.8/1.0/1.2-second silence, quiet nonzero noise, and optionally two fixed phrases using the installed macOS voice. It never records audio. Nonzero noise exercises the short-input decoding path; digital silence exercises the explicit silence gate.

`scripts/ci.sh` runs the entire existing check suite, builds the evaluator, runs help and owned audio validation, and verifies dependency pins before and after. `ECHO_ASR_SMOKE=1` explicitly allows acquisition of the tiny English model into an isolated build cache and executes the synthetic audio through actual ASR. CI enables this option. The smoke gate checks pipeline execution, not an accuracy target; inspect reported false insertions before changing speech thresholds.

Release packaging depends on this reusable validation job. A failing existing assertion blocks packaging; no checks are silently skipped. Some old assertions encode behavior intentionally corrected by this change, such as trimming saved snippet whitespace; those require a separately authorized expectation update if the project's prohibition on editing unit tests is retained.
