#!/usr/bin/env python3
# Requirement: generate one deterministic 6.056-second mono reference and exact upstream audio/DSP oracle tensors for Swift parity.
from __future__ import annotations

import argparse
import hashlib
import json
import math
import wave
from pathlib import Path

import numpy as np
import torch
import torchaudio
import torchaudio.compliance.kaldi as kaldi
import whisper



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


def matcha_mel(samples_24k: np.ndarray, source_root: Path) -> torch.Tensor:
    import sys
    matcha_root = str(source_root / "third_party/Matcha-TTS")
    if matcha_root not in sys.path:
        sys.path.insert(0, matcha_root)
    from matcha.utils.audio import mel_spectrogram
    waveform = torch.from_numpy(samples_24k).unsqueeze(0)
    return mel_spectrogram(
        waveform, n_fft=1920, num_mels=80, sampling_rate=24000,
        hop_size=480, win_size=1920, fmin=0, fmax=None, center=False
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--source-root", type=Path, required=True)
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)

    seconds = 6.056
    rate24 = 24000
    count24 = 145344
    t = np.arange(count24, dtype=np.float64) / rate24
    signal = (
        0.31 * np.sin(2 * math.pi * 173.0 * t)
        + 0.17 * np.sin(2 * math.pi * 511.0 * t + 0.3)
        + 0.11 * np.sin(2 * math.pi * 2207.0 * t + 0.9)
        + 0.05 * np.sin(2 * math.pi * (90.0 * t + 155.0 * t * t))
    ).astype(np.float32)
    wav = out / "reference-parity.wav"
    write_pcm16(wav, signal, rate24)

    loaded, loaded_rate = torchaudio.load(str(wav), backend="soundfile")
    if loaded_rate != rate24:
        raise RuntimeError(f"fixture decode sample rate mismatch: {loaded_rate}")
    samples24 = loaded.mean(dim=0)
    samples16 = torchaudio.transforms.Resample(rate24, 16000)(samples24)
    if samples24.numel() != 145344 or samples16.numel() != 96896:
        raise RuntimeError(f"sample count mismatch 24k={samples24.numel()} 16k={samples16.numel()}")

    whisper_feat = whisper.log_mel_spectrogram(samples16.unsqueeze(0), n_mels=128).cpu().numpy()
    camp = kaldi.fbank(
        samples16.unsqueeze(0),
        num_mel_bins=80,
        dither=0,
        sample_frequency=16000
    )
    camp = (camp - camp.mean(dim=0, keepdim=True)).unsqueeze(0).cpu().numpy()
    prompt = matcha_mel(samples24.cpu().numpy(), args.source_root.resolve()).squeeze(0).transpose(0, 1).unsqueeze(0).cpu().numpy()

    receipt = {
        "schemaVersion": 2,
        "status": "PASS_FIXTURE_GENERATED",
        "durationSeconds": seconds,
        "audio": {"file": wav.name, "sampleRate": rate24, "samples": count24, "sha256": sha256(wav)},
        "upstream": {
            "samples24k": save_f32(out / "samples24k.f32", samples24.cpu().numpy()),
            "samples16k": save_f32(out / "samples16k.f32", samples16.cpu().numpy()),
            "whisper128": save_f32(out / "whisper128.f32", whisper_feat),
            "campplusFbank": save_f32(out / "campplus_fbank.f32", camp),
            "promptMel": save_f32(out / "prompt_mel.f32", prompt),
        },
        "expectedShapes": {
            "samples24k": [145344],
            "samples16k": [96896],
            "whisper128": [1, 128, 605],
            "campplusFbank": [1, 604, 80],
            "promptMel": [1, 302, 80],
        },
        "resampler": "torchaudio==2.3.1 transforms.Resample default sinc_interp_hann width6 rolloff0.99",
    }
    for key, expected in receipt["expectedShapes"].items():
        actual = receipt["upstream"][key]["shape"]
        if actual != expected:
            raise RuntimeError(f"{key} shape {actual} != {expected}")
    (out / "reference_fixture.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt, indent=2))


if __name__ == "__main__":
    main()

# Code purpose: deterministic upstream decode/resample/DSP oracle for Swift reference preprocessing.
# Upstream: CosyVoice3_NPU@8789402; torchaudio==2.3.1; Matcha submodule dd9105b.
# Runtime: conversion/validation host only.
# Generated: 2026-10-02 America/New_York.
