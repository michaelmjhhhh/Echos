#!/usr/bin/env python3
"""Generate only owned synthetic audio; never read microphone or personal recordings."""
import argparse
import json
import random
import struct
import subprocess
import wave
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--speech", action="store_true", help="Use the installed macOS default voice for two fixed phrases")
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
cases = []

for duration in (0.3, 0.5, 0.8, 1.0, 1.2):
    name = f"silence-{duration:.1f}"
    path = args.output / f"{name}.wav"
    with wave.open(str(path), "wb") as output:
        output.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
        output.writeframes(b"\x00\x00" * round(duration * 16000))
    cases.append({"id": name, "audio": path.name, "reference": ""})

random_source = random.Random(20260925)
path = args.output / "quiet-noise-0.5.wav"
with wave.open(str(path), "wb") as output:
    output.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
    output.writeframes(b"".join(struct.pack("<h", random_source.randrange(-10, 11)) for _ in range(8000)))
cases.append({"id": "quiet-noise-0.5", "audio": path.name, "reference": ""})

if args.speech:
    for name, reference in (("speech-ready", "Echo is ready."), ("speech-short", "Yes.")):
        path = args.output / f"{name}.aiff"
        subprocess.run(["/usr/bin/say", "-o", str(path), reference], check=True)
        cases.append({"id": name, "audio": path.name, "reference": reference})

manifest = args.output / "manifest.json"
manifest.write_text(json.dumps({"cases": cases, "vocabulary": [], "replacements": [], "snippets": []}, indent=2) + "\n")
print(manifest)
