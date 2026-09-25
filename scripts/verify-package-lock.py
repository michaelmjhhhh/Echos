#!/usr/bin/env python3
"""Fail a build when any generated package pin differs from the reviewed lock."""
import json
from pathlib import Path

root = Path(__file__).resolve().parent.parent
expected = json.loads((root / "config/Package.resolved").read_text())
actual = json.loads((root / "Echo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved").read_text())

def pins(document):
    return sorted(document["pins"], key=lambda pin: pin["identity"])

if pins(expected) != pins(actual):
    raise SystemExit("Resolved dependencies differ from config/Package.resolved. Review and update the tracked lock explicitly.")
print("All resolved dependency revisions match config/Package.resolved.")
