#!/usr/bin/env python3
#@title export_reference_frontend_tables.py
# Requirement: export exact upstream mel filter matrices consumed by the native Swift reference DSP.
import argparse
import hashlib
import json
from pathlib import Path

import librosa
import numpy as np
import torch
import torchaudio.compliance.kaldi as kaldi
import whisper.audio as whisper_audio


def write(path: Path, array: np.ndarray):
    array = np.asarray(array, dtype="<f4", order="C")
    path.write_bytes(array.tobytes())
    return {
        "file": path.name,
        "shape": list(array.shape),
        "bytes": path.stat().st_size,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    }


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--output", type=Path, required=True)
    args = p.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)

    whisper128 = whisper_audio.mel_filters(torch.device("cpu"), 128).cpu().numpy()
    matcha80 = librosa.filters.mel(
        sr=24000, n_fft=1920, n_mels=80, fmin=0, fmax=None
    )
    kaldi80, _ = kaldi.get_mel_banks(
        num_bins=80,
        window_length_padded=512,
        sample_freq=16000.0,
        low_freq=20.0,
        high_freq=0.0,
        vtln_low=100.0,
        vtln_high=-500.0,
        vtln_warp_factor=1.0,
    )
    kaldi80 = kaldi80.cpu().numpy()

    receipt = {
        "status": "EXPORTED_TABLES",
        "whisper128": write(out / "whisper_mel_128.f32", whisper128),
        "kaldi80": write(out / "kaldi_mel_80.f32", kaldi80),
        "matcha80": write(out / "matcha_mel_80.f32", matcha80),
        "expectedShapes": {
            "whisper128": [128, 201],
            "kaldi80": [80, 256],
            "matcha80": [80, 961],
        },
        "upstream": {
            "whisper": "whisper.log_mel_spectrogram(..., n_mels=128)",
            "kaldi": "torchaudio.compliance.kaldi.fbank(..., num_mel_bins=80, dither=0, sample_frequency=16000)",
            "matcha": "matcha.utils.audio.mel_spectrogram n_fft=1920 n_mels=80 sr=24000 hop=480 win=1920 center=False",
        },
    }
    for key, expected in receipt["expectedShapes"].items():
        actual = receipt[key]["shape"]
        if actual != expected:
            raise RuntimeError(f"{key} shape {actual} != expected {expected}")
    (out / "reference_frontend_tables.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt, indent=2))


if __name__ == "__main__":
    main()

# Code purpose: freeze tiny deterministic DSP tables so shipping iOS does not need librosa/whisper/torchaudio.
# Upstream source: CosyVoice3_NPU@8789402 and Matcha-TTS submodule dd9105b34bf2be2230f4aa1e4769fb586a3c824e.
# Runtime: conversion host only.
# Generated: 2026-10-02 America/New_York.
