#!/usr/bin/env python3
# Requirement: generate one deterministic 6.056-second mono reference and upstream DSP oracle tensors for Swift parity.
from __future__ import annotations

import argparse
import hashlib
import json
import math
import wave
from pathlib import Path

import numpy as np
import torch
import torchaudio.compliance.kaldi as kaldi
import whisper

ROOT = Path(__file__).resolve().parents[2]


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save_f32(path: Path, value) -> dict:
    array = np.asarray(value, dtype="<f4", order="C")
    path.write_bytes(array.tobytes())
    return {"file": path.name, "shape": list(array.shape), "bytes": path.stat().st_size, "sha256": sha256(path)}


def write_pcm16(path: Path, samples: np.ndarray, sample_rate: int) -> None:
    pcm = np.clip(samples, -1, 1)
    pcm = np.round(pcm * 32767).astype("<i2")
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(sample_rate)
        output.writeframes(pcm.tobytes())


def resample_linear(samples: np.ndarray, source_rate: int, target_rate: int) -> np.ndarray:
    if source_rate == target_rate:
        return samples.astype(np.float32, copy=True)
    count = int(round(len(samples) * target_rate / source_rate))
    source_x = np.arange(len(samples), dtype=np.float64)
    target_x = np.arange(count, dtype=np.float64) * source_rate / target_rate
    return np.interp(target_x, source_x, samples).astype(np.float32)


def matcha_mel(samples_24k: np.ndarray) -> torch.Tensor:
    sys_path = str(ROOT / "third_party/Matcha-TTS")
    import sys
    if sys_path not in sys.path:
        sys.path.insert(0, sys_path)
    from matcha.utils.audio import mel_spectrogram
    waveform = torch.from_numpy(samples_24k).unsqueeze(0)
    return mel_spectrogram(
        waveform, n_fft=1920, num_mels=80, sampling_rate=24000,
        hop_size=480, win_size=1920, fmin=0, fmax=None, center=False
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)

    seconds = 6.056
    rate24 = 24000
    count24 = 145344
    t = np.arange(count24, dtype=np.float64) / rate24
    # Deterministic wide-band, non-clipping reference exercises low/high mel bins.
    signal = (
        0.31 * np.sin(2 * math.pi * 173.0 * t)
        + 0.17 * np.sin(2 * math.pi * 511.0 * t + 0.3)
        + 0.11 * np.sin(2 * math.pi * 2207.0 * t + 0.9)
        + 0.05 * np.sin(2 * math.pi * (90.0 * t + 155.0 * t * t))
    ).astype(np.float32)
    wav = out / "reference-parity.wav"
    write_pcm16(wav, signal, rate24)

    samples16 = resample_linear(signal, rate24, 16000)
    if len(samples16) != 96896:
        raise RuntimeError(f"16k sample count mismatch: {len(samples16)}")
    whisper_feat = whisper.log_mel_spectrogram(
        torch.from_numpy(samples16).unsqueeze(0), n_mels=128
    ).cpu().numpy()
    camp = kaldi.fbank(
        torch.from_numpy(samples16).unsqueeze(0),
        num_mel_bins=80, dither=0, sample_frequency=16000
    )
    camp = (camp - camp.mean(dim=0, keepdim=True)).unsqueeze(0).cpu().numpy()
    prompt = matcha_mel(signal).squeeze(0).transpose(0, 1).unsqueeze(0).cpu().numpy()

    receipt = {
        "schemaVersion": 1,
        "status": "PASS_FIXTURE_GENERATED",
        "durationSeconds": seconds,
        "audio": {"file": wav.name, "sampleRate": rate24, "samples": count24, "sha256": sha256(wav)},
        "samples16k": {"count": len(samples16)},
        "upstream": {
            "whisper128": save_f32(out / "whisper128.f32", whisper_feat),
            "campplusFbank": save_f32(out / "campplus_fbank.f32", camp),
            "promptMel": save_f32(out / "prompt_mel.f32", prompt),
        },
        "expectedShapes": {
            "whisper128": [1, 128, 605],
            "campplusFbank": [1, 604, 80],
            "promptMel": [1, 302, 80],
        },
        "note": "This fixture validates preprocessing only. Learned-model parity is a separate gate."
    }
    for key, expected in receipt["expectedShapes"].items():
        actual = receipt["upstream"][key]["shape"]
        if actual != expected:
            raise RuntimeError(f"{key} shape {actual} != {expected}")
    (out / "reference_fixture.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt, indent=2))


if __name__ == "__main__":
    main()

# Code purpose: deterministic upstream DSP oracle for Swift reference preprocessing.
# Upstream: CosyVoice3_NPU@8789402; Matcha submodule dd9105b.
# Runtime: conversion/validation host only.
# Generated: 2026-10-02 America/New_York.
