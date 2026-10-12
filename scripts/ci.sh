#!/bin/bash
set -euo pipefail
ECHO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ECHO_ROOT"
ECHO_BUILD_DIR="${ECHO_BUILD_DIR:-$ECHO_ROOT/build/ci}"
ECHO_PACKAGES_DIR="${ECHO_PACKAGES_DIR:-$ECHO_ROOT/build/SourcePackages}"
# Content-addressed Xcode compilation cache; CI restores it between runs.
ECHO_COMPILATION_CACHE="${ECHO_COMPILATION_CACHE:-$ECHO_ROOT/build/CompilationCache}"
xcodebuild -version
xcodegen --version
xcodegen generate
xcodebuild -project Echo.xcodeproj -scheme Echo -resolvePackageDependencies \
  -clonedSourcePackagesDirPath "$ECHO_PACKAGES_DIR" -onlyUsePackageVersionsFromResolvedFile
python3 scripts/verify-package-lock.py
ECHO_BUILD_ARGUMENTS=(-project Echo.xcodeproj -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$ECHO_BUILD_DIR" -clonedSourcePackagesDirPath "$ECHO_PACKAGES_DIR" \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile ARCHS=arm64 \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO \
  COMPILATION_CACHE_ENABLE_CACHING=YES COMPILATION_CACHE_CAS_PATH="$ECHO_COMPILATION_CACHE")
# Existing suite remains a required gate. Obsolete assertions must be reviewed;
# this script never skips a check or turns failures into a successful release.
xcodebuild "${ECHO_BUILD_ARGUMENTS[@]}" -scheme Echo -configuration Debug test
# Debug reuses the dependency builds from the test run above; the smoke replay
# checks pipeline behavior, not speed. Measure latency with a Release build.
xcodebuild "${ECHO_BUILD_ARGUMENTS[@]}" -scheme EchoEvaluate -configuration Debug build
ECHO_EVALUATOR="$ECHO_BUILD_DIR/Build/Products/Debug/EchoEvaluate"
"$ECHO_EVALUATOR" --help
python3 scripts/make-evaluation-fixtures.py --output "$ECHO_BUILD_DIR/replay-fixtures"
"$ECHO_EVALUATOR" --manifest "$ECHO_BUILD_DIR/replay-fixtures/manifest.json" \
  --validate-only --output "$ECHO_BUILD_DIR/replay-validation.json"
if [ "${ECHO_ASR_SMOKE:-0}" = "1" ]; then
  # This opt-in is explicit: clean CI runners must acquire their synthetic smoke model.
  ECHO_BUILD_REVISION="$(git rev-parse HEAD)" "$ECHO_EVALUATOR" \
    --manifest "$ECHO_BUILD_DIR/replay-fixtures/manifest.json" \
    --model openai_whisper-tiny.en --download-base "$ECHO_BUILD_DIR/model-cache" --download \
    --prompt-budgets 0 --fallbacks 0 --output "$ECHO_BUILD_DIR/replay-smoke.json"
  python3 - "$ECHO_BUILD_DIR/replay-smoke.json" <<'PYTHON'
import json
import sys
report = json.load(open(sys.argv[1]))
rows = report["rows"]
if report["failedCases"] or len(rows) != 6:
    raise SystemExit("Audio replay did not complete all owned smoke fixtures.")
for row in rows:
    if row["id"].startswith("silence-"):
        if not row["digitalSilence"] or row["rawCharacterCount"] != 0:
            raise SystemExit("Digital-silence policy regressed.")
    elif row["id"] == "quiet-noise-0.5" and row["encoderRuns"] < 1:
        raise SystemExit("The short-input fixture skipped actual model encoding.")
print("Owned audio replay verified silence handling and real short-input encoding.")
PYTHON
fi
python3 scripts/verify-package-lock.py
