#!/usr/bin/env python3
"""Synthesize Ovid's original "digital chime" notification sound.

The sound is generated from scratch with two-operator FM synthesis; nothing
is sampled or copied. Running this script is deterministic (no randomness),
so the committed resource can be re-created byte for byte:

    python3 tool/gen_notification_sound.py            # (re)write the .wav
    python3 tool/gen_notification_sound.py --check    # verify committed file

Design (0.68 s, 44.1 kHz, mono, 16-bit PCM, peak normalised to -3 dBFS):
  * Three rising notes, G5 -> D6 -> B6 (784 / 1174.66 / 1975.53 Hz), onsets
    0 / 95 / 190 ms. The open fifth then major sixth reads as "done, good",
    and the high last note gives the digital sparkle.
  * Each note is an FM bell: carrier f, modulator 1.4 * f (slightly
    inharmonic = glassy), modulation index decaying 2.2 -> 0.2 so the tone
    starts bright and settles into a near-pure sine.
  * A quiet sine an octave above each note adds air.
  * Envelope: 8 ms raised-cosine (soft) attack, exponential decay
    (tau 110-170 ms, longer for later notes), 70 ms cosine fade at the end
    so the file never clicks.
  * Output is written as WAV because no Ogg/Vorbis encoder is required to
    rebuild it; Android plays raw WAV notification sounds natively.
"""

from __future__ import annotations

import argparse
import math
import struct
import sys
import wave
from pathlib import Path

RATE = 44_100
DURATION_S = 0.68
PEAK_DBFS = -3.0
OUT = (
    Path(__file__).resolve().parent.parent
    / "android/app/src/main/res/raw/ovid_chime.wav"
)

# (frequency Hz, onset s, decay tau s, gain)
NOTES = (
    (783.99, 0.000, 0.110, 0.80),
    (1174.66, 0.095, 0.135, 0.70),
    (1975.53, 0.190, 0.170, 0.62),
)
MOD_RATIO = 1.4
INDEX_START = 2.2
INDEX_END = 0.2
INDEX_TAU = 0.060
ATTACK_S = 0.008
FADE_S = 0.070


def _note(t: float, freq: float, tau: float) -> float:
    """One FM bell voice at local time t (s) >= 0."""
    if t < ATTACK_S:
        attack = 0.5 - 0.5 * math.cos(math.pi * t / ATTACK_S)
    else:
        attack = 1.0
    env = attack * math.exp(-t / tau)
    index = INDEX_END + (INDEX_START - INDEX_END) * math.exp(-t / INDEX_TAU)
    mod = index * math.sin(2 * math.pi * freq * MOD_RATIO * t)
    body = math.sin(2 * math.pi * freq * t + mod)
    air = 0.12 * math.sin(2 * math.pi * 2 * freq * t)
    return env * (body + air)


def synthesize() -> list[float]:
    n = int(RATE * DURATION_S)
    out = [0.0] * n
    for i in range(n):
        t = i / RATE
        s = 0.0
        for freq, onset, tau, gain in NOTES:
            if t >= onset:
                s += gain * _note(t - onset, freq, tau)
        remaining = DURATION_S - t
        if remaining < FADE_S:
            s *= 0.5 - 0.5 * math.cos(math.pi * remaining / FADE_S)
        out[i] = s
    peak = max(abs(v) for v in out) or 1.0
    target = 10 ** (PEAK_DBFS / 20)
    return [v * target / peak for v in out]


def encode(samples: list[float]) -> bytes:
    return b"".join(
        struct.pack("<h", max(-32768, min(32767, round(v * 32767))))
        for v in samples
    )


def write(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(encode(synthesize()))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true",
                        help="fail if the committed file differs")
    parser.add_argument("--out", type=Path, default=OUT)
    args = parser.parse_args()
    if args.check:
        with wave.open(str(args.out), "rb") as w:
            frames = w.readframes(w.getnframes())
        if frames != encode(synthesize()):
            print(f"{args.out} is stale; rerun {Path(__file__).name}",
                  file=sys.stderr)
            return 1
        print(f"{args.out} is up to date")
        return 0
    write(args.out)
    print(f"wrote {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
