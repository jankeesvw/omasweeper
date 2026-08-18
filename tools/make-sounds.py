#!/usr/bin/env python3
"""Generate the sound set: 8-bit mono square waves, the way a cabinet did it.

Run from the repo root to regenerate sounds/:  python3 tools/make-sounds.py

Everything here is deliberately crude. 22050Hz, 8-bit unsigned, hard square
waves with a 2ms fade at each end so a blip stops without a click of its own.
The files are committed, so nobody has to run this to play the game.
"""
import math
import os
import random
import struct
import wave

RATE = 22050
FADE = int(RATE * 0.002)


def square(freq_from, freq_to, ms, volume=0.5, duty=0.5):
    """A square wave sweeping between two frequencies."""
    n = int(RATE * ms / 1000)
    out = []
    phase = 0.0
    for i in range(n):
        f = freq_from + (freq_to - freq_from) * (i / max(1, n - 1))
        phase += f / RATE
        out.append(volume if (phase % 1.0) < duty else -volume)
    return out


def noise(ms, volume=0.5, decay=True):
    n = int(RATE * ms / 1000)
    rng = random.Random(1983)  # fixed, so a rebuild produces the same file
    return [rng.uniform(-volume, volume) * ((1 - i / n) if decay else 1) for i in range(n)]


def silence(ms):
    return [0.0] * int(RATE * ms / 1000)


def envelope(samples):
    n = len(samples)
    for i in range(min(FADE, n)):
        samples[i] *= i / FADE
        samples[n - 1 - i] *= i / FADE
    return samples


def write(name, samples):
    samples = envelope(list(samples))
    frames = b"".join(
        struct.pack("B", max(0, min(255, int(round(s * 127)) + 128))) for s in samples
    )
    path = os.path.join(os.path.dirname(__file__), "..", "sounds", name + ".wav")
    with wave.open(os.path.abspath(path), "wb") as f:
        f.setnchannels(1)
        f.setsampwidth(1)
        f.setframerate(RATE)
        f.writeframes(frames)
    print(name, len(samples) / RATE, "s")


def mix(a, b):
    n = max(len(a), len(b))
    a = a + [0.0] * (n - len(a))
    b = b + [0.0] * (n - len(b))
    return [x + y for x, y in zip(a, b)]


# Opening a cell: the sound you hear most, so it is the shortest and quietest.
write("open", square(760, 1080, 32, 0.28))

# Flagging and taking a flag back: the same two notes, either way up.
write("flag", square(1400, 1400, 22, 0.30) + silence(14) + square(2100, 2100, 26, 0.30))
write("unflag", square(2100, 2100, 22, 0.28) + silence(14) + square(1400, 1400, 26, 0.28))

# Clearing around a number: three cells opening at once, so three blips.
write("chord", square(900, 900, 20, 0.26) + silence(8)
       + square(1200, 1200, 20, 0.26) + silence(8)
       + square(1500, 1500, 24, 0.26))

# A new board: a rising sweep, the sound of dealing.
write("deal", square(520, 1040, 70, 0.24))

# The mine: a low sweep under a burst of noise.
write("boom", mix(square(240, 55, 460, 0.42, duty=0.32), noise(300, 0.34)))

# Cleared: the arpeggio, with the octave held at the end.
write("win", square(523, 523, 80, 0.30) + square(659, 659, 80, 0.30)
       + square(784, 784, 80, 0.30) + square(1046, 1046, 240, 0.32))
