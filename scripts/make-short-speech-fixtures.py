#!/usr/bin/env python3
"""Generate local synthetic speech for EchoEvaluate, without microphone/user data.

Requires macOS `say`, `afconvert`, and an already installed English voice.
Example: python3 scripts/make-short-speech-fixtures.py --output /tmp/echo-short-speech
Results are integration fixtures, not a representative recognition benchmark.
"""

import argparse
import array
import json
import pathlib
import subprocess
import sys
import wave

SAMPLE_RATE = 16_000


def read_pcm(path):
    with wave.open(str(path), "rb") as source:
        if (source.getnchannels(), source.getsampwidth(), source.getframerate()) != (1, 2, SAMPLE_RATE):
            raise ValueError("Expected mono, 16-bit, 16 kHz PCM")
        samples = array.array("h", source.readframes(source.getnframes()))
    if sys.byteorder != "little":
        samples.byteswap()
    return samples


def write_pcm(path, samples):
    samples = array.array("h", samples)
    if sys.byteorder != "little":
        samples.byteswap()
    with wave.open(str(path), "wb") as destination:
        destination.setnchannels(1)
        destination.setsampwidth(2)
        destination.setframerate(SAMPLE_RATE)
        destination.writeframes(samples.tobytes())


def silence(seconds):
    return array.array("h", [0]) * round(seconds * SAMPLE_RATE)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--voice", default="Samantha")
    parser.add_argument("--rate", type=int, default=240)
    args = parser.parse_args()
    output = args.output.expanduser().resolve()
    output.mkdir(parents=True, exist_ok=True)
    subprocess.run(["say", "-v", args.voice, "-r", str(args.rate), "-o", str(output / "yes.aiff"), "Yes"], check=True)
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", str(output / "yes.aiff"), str(output / "yes.wav")], check=True)
    samples = read_pcm(output / "yes.wav")
    peak = max(abs(value) for value in samples)
    active = [index for index, value in enumerate(samples) if abs(value) > peak * 0.01]
    if not active:
        raise ValueError("Speech synthesis returned no nonzero audio")
    # Preserve 10 ms around the active signal, then crop/pad to exact durations.
    word = samples[max(0, active[0] - 160):min(len(samples), active[-1] + 160)]
    cases = []
    for seconds in (0.3, 0.5, 0.8, 1.0, 1.2):
        length = round(seconds * SAMPLE_RATE)
        values = word[:length] + array.array("h", [0]) * max(0, length - len(word))
        name = f"yes-{seconds:.1f}"
        write_pcm(output / f"{name}.wav", values)
        cases.append({"id": name, "audio": f"{name}.wav", "reference": "yes"})
    for seconds in (0.3, 1.2):
        name = f"silence-{seconds:.1f}"
        write_pcm(output / f"{name}.wav", silence(seconds))
        cases.append({"id": name, "audio": f"{name}.wav", "reference": ""})
    quiet = array.array("h", [round(value * 0.02) for value in read_pcm(output / "yes-1.2.wav")])
    write_pcm(output / "quiet-yes-1.2.wav", quiet)
    cases.append({"id": "quiet-yes-1.2", "audio": "quiet-yes-1.2.wav", "reference": "yes"})
    (output / "manifest.json").write_text(json.dumps({"cases": cases, "vocabulary": ["Echo", "OpenAI"]}, indent=2) + "\n")

    boundary_cases = []
    word = read_pcm(output / "yes-0.5.wav")
    for duration, onsets in ((29, [0.1, 28.2]), (30, [0.1, 29.2]), (31, [0.1, 30.2]),
                             (59, [0.1, 30.2, 58.2]), (60, [0.1, 30.2, 59.2]), (61, [0.1, 30.2, 60.2])):
        values = silence(duration)
        for onset in onsets:
            start = round(onset * SAMPLE_RATE)
            values[start:start + len(word)] = word
        name = f"boundary-{duration}"
        write_pcm(output / f"{name}.wav", values)
        boundary_cases.append({"id": name, "audio": f"{name}.wav", "reference": " ".join(["yes"] * len(onsets))})
    (output / "boundary-manifest.json").write_text(json.dumps({"cases": boundary_cases}, indent=2) + "\n")
    print(f"Created {len(cases)} short/silence/quiet fixtures and {len(boundary_cases)} boundary fixtures in {output}")
    print(f"Synthesized word duration: {len(read_pcm(output / 'yes.wav')) / SAMPLE_RATE:.4f}s; voice={args.voice}, rate={args.rate}")


if __name__ == "__main__":
    main()
