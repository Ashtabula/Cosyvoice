#!/usr/bin/env python3
#@title convert_reference_onnx_to_coreml.py
# Requirement: convert the selected single-reference speech tokenizer and CAMPPlus ONNX graphs into fixed-profile Core ML packages.
# Requirement: preserve input/output names used by frontend.py and emit a machine-readable receipt; conversion is NOT promotion.
import argparse
import hashlib
import json
from pathlib import Path

import coremltools as ct
import numpy as np
import onnx
import torch
from onnx2torch import convert


class SpeechTokenizer(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, feats, feats_length):
        value = self.model(feats, feats_length)
        if isinstance(value, (tuple, list)):
            value = value[0]
        return value


class CampPlus(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, input):
        value = self.model(input)
        if isinstance(value, (tuple, list)):
            value = value[0]
        return value


def package_hash(path: Path):
    h = hashlib.sha256()
    total = 0
    for file in sorted(p for p in path.rglob("*") if p.is_file()):
        payload = file.read_bytes()
        h.update(str(file.relative_to(path)).encode())
        h.update(payload)
        total += len(payload)
    return h.hexdigest(), total


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--speech-tokenizer", type=Path, required=True)
    p.add_argument("--campplus", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    args = p.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)

    speech_onnx = onnx.load(str(args.speech_tokenizer))
    camp_onnx = onnx.load(str(args.campplus))
    speech_torch = SpeechTokenizer(convert(speech_onnx).eval()).eval()
    camp_torch = CampPlus(convert(camp_onnx).eval()).eval()

    speech_example = (
        torch.zeros(1, 128, 605, dtype=torch.float32),
        torch.tensor([605], dtype=torch.int32),
    )
    camp_example = torch.zeros(1, 604, 80, dtype=torch.float32)

    with torch.inference_mode():
        speech_trace = torch.jit.trace(speech_torch, speech_example, check_trace=False)
        camp_trace = torch.jit.trace(camp_torch, (camp_example,), check_trace=False)

    speech_model = ct.convert(
        speech_trace,
        inputs=[
            ct.TensorType(name="feats", shape=speech_example[0].shape, dtype=np.float32),
            ct.TensorType(name="feats_length", shape=speech_example[1].shape, dtype=np.int32),
        ],
        outputs=[ct.TensorType(name="indices")],
        minimum_deployment_target=ct.target.iOS18,
        compute_precision=ct.precision.FLOAT32,
        compute_units=ct.ComputeUnit.CPU_ONLY,
        convert_to="mlprogram",
    )
    camp_model = ct.convert(
        camp_trace,
        inputs=[ct.TensorType(name="input", shape=camp_example.shape, dtype=np.float32)],
        outputs=[ct.TensorType(name="output")],
        minimum_deployment_target=ct.target.iOS18,
        compute_precision=ct.precision.FLOAT32,
        compute_units=ct.ComputeUnit.CPU_ONLY,
        convert_to="mlprogram",
    )

    speech_path = out / "speech-tokenizer-fixed605.mlpackage"
    camp_path = out / "campplus-fixed604.mlpackage"
    speech_model.save(str(speech_path))
    camp_model.save(str(camp_path))
    speech_hash, speech_bytes = package_hash(speech_path)
    camp_hash, camp_bytes = package_hash(camp_path)

    receipt = {
        "status": "CONVERTED_NOT_PARITY_VALIDATED",
        "profile": "fixed225-reference605-604",
        "speechTokenizer": {
            "path": str(speech_path),
            "input": {"feats": [1, 128, 605], "feats_length": [1]},
            "output": "indices",
            "sha256": speech_hash,
            "bytes": speech_bytes,
        },
        "campPlus": {
            "path": str(camp_path),
            "input": {"input": [1, 604, 80]},
            "output": "output",
            "sha256": camp_hash,
            "bytes": camp_bytes,
        },
        "promotion": "requires upstream ONNX numerical parity and physical-iPhone parity before referenceEnrollment.status may become PASS_DEVICE_PARITY",
    }
    (out / "reference_coreml_conversion.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt, indent=2))


if __name__ == "__main__":
    main()

# Code purpose: produce fixed-profile Core ML candidates for the two learned reference-enrollment graphs.
# Upstream source assets: speech_tokenizer_v3.onnx and campplus.onnx from Fun-CosyVoice3-0.5B-2512 revision29e01c4e.
# Runtime: conversion host; requires coremltools, onnx, onnx2torch, torch.
# Generated: 2026-10-02 America/New_York.
