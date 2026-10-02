#@title export_dynamic_flow_conditions.py
# Requirement: export generic per-reference Flow conditioning. No prompt token, prompt mel, or speaker embedding may be frozen as a model buffer.
import argparse
import hashlib
import json
import sys
from pathlib import Path

import coremltools as ct
import numpy as np
import torch

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from reference_flow_conditions import EXPECTED_KEYS, load_reference_flow_conditioning


def file_sha256(path: Path):
    h = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--model-dir", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--prompt-token-count", type=int, default=151)
    p.add_argument("--prompt-frame-count", type=int, default=302)
    args = p.parse_args()

    flow_pt = args.model_dir / "flow.pt"
    module = load_reference_flow_conditioning(flow_pt)

    examples = (
        torch.zeros(1, 225, dtype=torch.int32),
        torch.zeros(1, args.prompt_token_count, dtype=torch.int32),
        torch.zeros(1, args.prompt_frame_count, 80, dtype=torch.float32),
        torch.zeros(1, 192, dtype=torch.float32),
    )
    traced = torch.jit.trace(module, examples, check_trace=False)
    model = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="tokens", shape=examples[0].shape, dtype=np.int32),
            ct.TensorType(name="prompt_tokens", shape=examples[1].shape, dtype=np.int32),
            ct.TensorType(name="prompt_feat", shape=examples[2].shape, dtype=np.float32),
            ct.TensorType(name="speaker", shape=examples[3].shape, dtype=np.float32),
        ],
        outputs=[
            ct.TensorType(name="mu"),
            ct.TensorType(name="spks"),
            ct.TensorType(name="cond"),
        ],
        minimum_deployment_target=ct.target.iOS18,
        compute_precision=ct.precision.FLOAT32,
        compute_units=ct.ComputeUnit.CPU_ONLY,
        convert_to="mlprogram",
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    model.save(str(args.output))

    receipt = {
        "schemaVersion": 1,
        "status": "EXPORTED_NOT_DEVICE_VALIDATED",
        "scope": "generic per-reference Flow conditioning",
        "output": str(args.output),
        "inputs": ["tokens", "prompt_tokens", "prompt_feat", "speaker"],
        "promptTokenCount": args.prompt_token_count,
        "promptFrameCount": args.prompt_frame_count,
        "flowPtSha256": file_sha256(flow_pt),
        "loadedWeightKeys": sorted(EXPECTED_KEYS),
        "construction": "minimal upstream-equivalent conditioning graph; full cosyvoice3.yaml intentionally not instantiated",
    }
    receipt_path = args.output.parent / "flow_conditions_dynamic_export.json"
    receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt, indent=2))


if __name__ == "__main__":
    main()

# Code purpose: remove the benchmark-only baked reference from flow-conditions without importing unrelated LLM/HiFT/server dependencies.
# Upstream math: CausalMaskedDiffWithDiT conditioning path + PreLookaheadLayer at CosyVoice3_NPU@878940245562bcd1dd0231d78157ba78d70b39f6.
# Runtime: conversion host only; generated package requires parity and device validation before promotion.
# Generated: 2026-10-02 America/New_York.
