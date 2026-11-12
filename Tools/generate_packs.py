#!/usr/bin/env python3
"""
generate_packs.py - builds Thock's sound packs from the Mechvibes/ClickClack
recordings (MIT, see Resources/upstream.clickclack/CLICKCLACK-LICENSE).

Each pack becomes a directory of short 48 kHz mono WAVs:

    <group>_<press|release>_t<tier>_v<variant>.wav

where tier is 0..3 (soft, medium, hard, slam) and variant is a distinct recording
of the same key group, played round-robin so repeated presses never sound identical.

A handful of packs are synthesised in-process (no upstream recording exists for a
MacBook scissor switch, a membrane dome or a typewriter platen).
"""

import json
import math
import os
import random
import subprocess
import sys
import wave
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
UPSTREAM = ROOT / "Resources" / "upstream.clickclack" / "switchtypes"
OUT = ROOT / "Resources" / "Packs"
SR = 48000

TIERS = ["soft", "medium", "hard", "slam"]

PACKS = {
    "alpaca":     {"name": "Alpaca Linear",         "family": "linear"},
    "blackink":   {"name": "Gateron Black Ink V2",  "family": "thocky"},
    "bluealps":   {"name": "Alps Blue",             "family": "vintage"},
    "boxnavy":    {"name": "Kailh BOX Navy",        "family": "clicky"},
    "buckling":   {"name": "IBM Buckling Spring",   "family": "vintage"},
    "cream":      {"name": "NovelKeys Cream",       "family": "linear"},
    "holypanda":  {"name": "Holy Panda",            "family": "thocky"},
    "mxblack":    {"name": "Cherry MX Black",       "family": "linear"},
    "mxblue":     {"name": "Cherry MX Blue",        "family": "clicky"},
    "mxbrown":    {"name": "Cherry MX Brown",       "family": "tactile"},
    "redink":     {"name": "Gateron Red Ink V2",    "family": "linear"},
    "topre":      {"name": "Topre",                 "family": "thocky"},
    "turquoise":  {"name": "Turquoise Tealios",     "family": "linear"},
    # synthesised, see synth_pack()
    "scissor":    {"name": "MacBook Scissor",       "family": "scissor", "synth": True},
    "membrane":   {"name": "Rubber Membrane",       "family": "membrane", "synth": True},
    "typewriter": {"name": "Vintage Typewriter",    "family": "typewriter", "synth": True},
}


# --------------------------------------------------------------- utilities

def decode_to_wav(src: Path, dst: Path) -> bool:
    r = subprocess.run(
        ["afconvert", str(src), "-o", str(dst), "-f", "WAVE", "-d", "LEI16", "-r", str(SR)],
        capture_output=True,
    )
    return r.returncode == 0 and dst.exists()


def read_wav(path: Path):
    with wave.open(str(path), "rb") as w:
        assert w.getnchannels() == 1 and w.getsampwidth() == 2, path
        n = w.getnframes()
        rate = w.getframerate()
        data = np.frombuffer(w.readframes(n), dtype="<i2").astype(np.float64) / 32768.0
    return rate, data


def write_wav(path: Path, data: np.ndarray):
    path.parent.mkdir(parents=True, exist_ok=True)
    clipped = np.clip(data, -1.0, 1.0)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes((clipped * 32767.0).astype("<i2").tobytes())


def resample(x: np.ndarray, factor: float) -> np.ndarray:
    """factor > 1 = slower/longer, < 1 = faster/shorter (linear interp)."""
    if factor == 1.0 or len(x) == 0:
        return x
    n = max(1, int(round(len(x) * factor)))
    idx = np.linspace(0, len(x) - 1, n)
    return np.interp(idx, np.arange(len(x)), x)


def one_pole_lowpass(x: np.ndarray, fc: float, sr: int) -> np.ndarray:
    a = math.exp(-2.0 * math.pi * fc / sr)
    y = np.empty_like(x)
    acc = 0.0
    for i, v in enumerate(x):
        acc = (1.0 - a) * v + a * acc
        y[i] = acc
    return y


def trim(x: np.ndarray, sr: int) -> np.ndarray:
    """Remove leading/trailing near-silence, keep a hair of decay."""
    if len(x) == 0:
        return x
    peak = float(np.max(np.abs(x))) or 1.0
    thr = max(0.0015, peak * 0.01)
    nz = np.nonzero(np.abs(x) > thr)[0]
    if len(nz) == 0:
        return x[: int(5 * sr / 1000)]
    start = max(0, int(nz[0]) - int(2 * sr / 1000))
    end = min(len(x), int(nz[-1]) + int(18 * sr / 1000))
    return x[start:end]


def normalize_peak(x: np.ndarray, target: float = 0.9) -> np.ndarray:
    p = float(np.max(np.abs(x)))
    return x if p == 0 else x * (target / p)


# --------------------------------------------------------- tier processing

TIER_GAIN = [0.34, 0.62, 1.0, 1.32]
TIER_RATE = [0.94, 0.975, 1.0, 1.06]
TIER_LPFC = [2400.0, 3300.0, 4800.0, 7000.0]
TIER_TAIL = [0.78, 0.92, 1.0, 1.08]


def make_tier(x: np.ndarray, tier: int, sr: int = SR) -> np.ndarray:
    """Derive one force tier from a single recorded take."""
    y = resample(x, 1.0 / TIER_RATE[tier])

    # timbre: light touches darker and duller, slams brighter and punchier
    lp = one_pole_lowpass(y, TIER_LPFC[tier], sr)
    hi = y - one_pole_lowpass(y, 3000.0, sr)
    y = lp + hi * (0.22 * tier)

    # articulation length: soft taps decay quickly, slams ring longer
    tail = TIER_TAIL[tier]
    cut = int(len(y) * tail)
    if cut < len(y):
        fade = np.ones(len(y))
        fade[cut:] = np.linspace(1.0, 0.0, len(y) - cut) ** 1.5
        y = y * fade

    # attack shaping
    pre = max(1, int(2.0 * sr / 1000))
    env = np.ones(len(y))
    env[:pre] = np.linspace([0.42, 0.68, 0.86, 1.25][tier], 1.0, pre)
    y = y * env

    y = normalize_peak(y, 0.9) * TIER_GAIN[tier]
    return y


# ------------------------------------------------------ synthesised packs

def mix_to_len(*signals):
    """Sum signals of differing lengths into a common-length buffer."""
    n = max(len(s) for s in signals)
    out = np.zeros(n)
    for s in signals:
        out[: len(s)] += s[:n]
    return out


def synth_click(rng, sr=SR, dur=0.045, fc=2600.0):
    n = int(dur * sr)
    t = np.arange(n) / sr
    noise = rng.standard_normal(n)
    click = one_pole_lowpass(noise, fc, sr)
    env = np.exp(-t / (dur * 0.18)) * (1 - np.exp(-t / (dur * 0.008)))
    return click * env


def synth_body(rng, sr=SR, dur=0.09, f0=190.0, decay=0.02):
    n = int(dur * sr)
    t = np.arange(n) / sr
    f = f0 * np.exp(-t / (decay * 4))
    phase = 2 * np.pi * np.cumsum(f) / sr
    body = np.sin(phase) * np.exp(-t / decay)
    body += 0.4 * np.sin(2 * phase) * np.exp(-t / (decay * 0.6))
    return body


def synth_take(rng, family, sr=SR):
    """One synthesised recording of a switch for a given family."""
    if family == "scissor":
        return mix_to_len(0.9 * synth_click(rng, sr, 0.030, 1800.0),
                          1.1 * synth_body(rng, sr, 0.055, 300.0, 0.012))
    if family == "membrane":
        return mix_to_len(0.6 * synth_click(rng, sr, 0.020, 900.0),
                          1.3 * synth_body(rng, sr, 0.06, 240.0, 0.016))
    if family == "typewriter":
        n = int(0.02 * sr)
        t = np.arange(n) / sr
        bell = 0.35 * np.sin(2 * np.pi * 2600 * t)
        bell *= np.exp(-t / 0.004)
        return mix_to_len(0.7 * synth_click(rng, sr, 0.012, 3200.0),
                          1.0 * synth_body(rng, sr, 0.10, 150.0, 0.025),
                          bell)
    return synth_click(rng)


def synth_pack(pack_id: str, spec: dict):
    rng = np.random.default_rng(abs(hash(pack_id)) & 0xFFFFFFFF)
    out_dir = OUT / pack_id
    out_dir.mkdir(parents=True, exist_ok=True)
    for group in ("generic", "enter", "space", "backspace"):
        for event in ("press", "release"):
            variants = 5 if event == "press" else 1
            for v in range(variants):
                base = synth_take(rng, spec["family"])
                for t in range(4):
                    write_wav(out_dir / f"{group}_{event}_t{t}_v{v}.wav",
                              make_tier(base, t))


# ----------------------------------------------------------------- driver

def group_and_variant(filename: str):
    """GENERIC_R0 -> ("generic", 1); ENTER -> ("enter", 0)."""
    stem = Path(filename).stem.upper()
    mapping = {"ENTER": "enter", "SPACE": "space", "BACKSPACE": "backspace",
               "GENERIC": "generic"}
    if stem in mapping:
        return mapping[stem], 0
    for base, name in mapping.items():
        if stem.startswith(base + "_R"):
            try:
                return name, int(stem.split("_R")[-1]) + 1
            except ValueError:
                pass
        if stem.startswith(base + "_"):
            return name, 5
    return None, None


def build_recording_pack(pack_id: str):
    src = UPSTREAM / pack_id
    out_dir = OUT / pack_id
    out_dir.mkdir(parents=True, exist_ok=True)
    tmp = out_dir / ".tmp"
    tmp.mkdir(exist_ok=True)

    for event in ("press", "release"):
        d = src / event
        if not d.is_dir():
            continue
        for mp3 in sorted(d.glob("*.mp3")):
            group, variant = group_and_variant(mp3.name)
            if group is None:
                print(f"  ! skipping unknown key group file {mp3.name}")
                continue
            wav_path = tmp / f"{group}_{event}_{variant}.wav"
            if not decode_to_wav(mp3, wav_path):
                print(f"  ! decode failed: {mp3}")
                continue
            _, audio = read_wav(wav_path)
            audio = trim(audio, SR)
            if len(audio) < 64:
                continue
            for t in range(4):
                write_wav(out_dir / f"{group}_{event}_t{t}_v{variant}.wav",
                          make_tier(audio, t))
    # clean tmp
    for f in tmp.glob("*.wav"):
        f.unlink()
    tmp.rmdir()


def main():
    only = sys.argv[1:] if len(sys.argv) > 1 else None
    OUT.mkdir(parents=True, exist_ok=True)
    built = []
    for pack_id, spec in PACKS.items():
        if only and pack_id not in only:
            continue
        if spec.get("synth"):
            synth_pack(pack_id, spec)
        else:
            build_recording_pack(pack_id)
        meta = dict(spec)
        meta.update({"id": pack_id, "source": "Mechvibes/ClickClack (MIT)"})
        meta.pop("synth", None)
        (OUT / pack_id / "pack.json").write_text(json.dumps(meta, indent=1))
        n = len(list((OUT / pack_id).glob("*.wav")))
        built.append((pack_id, n))
        print(f"  built {pack_id:11s} {n:4d} clips  ({spec['name']})")

    print(f"\n{len(built)} packs, {sum(n for _, n in built)} clips total")


if __name__ == "__main__":
    main()
