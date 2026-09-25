#!/bin/bash
set -euo pipefail
ECHO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ECHO_LOCK_DIRECTORY="$ECHO_ROOT/Echo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
mkdir -p "$ECHO_LOCK_DIRECTORY"
cp "$ECHO_ROOT/config/Package.resolved" "$ECHO_LOCK_DIRECTORY/Package.resolved"
