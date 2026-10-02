#!/usr/bin/env python3
# Requirement: prove the generic Core ML Flow-conditioning graph matches the exact fixed-profile PyTorch conditioning subgraph loaded directly from flow.pt.
from __future__ import annotations

import argparse
import hashlib
import json
import platform
import sys
from pathlib import Path

import coremltools as ct
import numpy as np
import torch

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from reference_flow_conditions import load_reference_flow_conditioning


def tree_sha256(path: Path) -> str:
    h = hashlib.sha256()
    for file in sorted(p for p in path.rglob("*") if p.is_file()):
        h.update(str(file.relative_to(path)).encode())
        h.update(file.read_bytes())
    return h.hexdigest()


def file_sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def compare(name: str, expected: np.ndarray, observed: np.ndarray, atol: float = 3e-4, rtol: float = 3e-4) -> dict:
    if expected.shape != observed.shape:
        return {
            "name": name,
            "pass": False,
            "shapeExpected": list(expected.shape),
            "shapeObserved": list(observed.shape),
        }
    diff = np.abs(expected.astype(np.float64) - observed.astype(np.float64))
    scale = np.maximum(
        np.abs(expected.astype(np.float64)),
        np.abs(observed.astype(np.float64)),
    )
    passed = bool(np.isfinite(observed).all() and np.all(diff <= atol + rtol * scale))
    return {
        "name": name,
        "pass": passed,
        "maxAbs": float(diff.max(initial=0)),
        "meanAbs": float(diff.mean()),
        "atol": atol,
        "rtol": rtol,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    # Retained for CLI compatibility and provenance even though the minimal
    # conditioning replica no longer imports the full source package.
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--model-dir", type=Path, required=True)
    parser.add_argument("--coreml", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    if platform.system() != "Darwin":
        raise RuntimeError("Core ML prediction parity must run on macOS")

    flow_pt = args.model_dir.resolve() / "flow.pt"
    reference = load_reference_flow_conditioning(flow_pt)

    rng = np.random.default_rng(1986)
    tokens = rng.integers(0, 6561, size=(1, 225), dtype=np.int32)
    prompt_tokens = rng.integers(0, 6561, size=(1, 151), dtype=np.int32)
    prompt_feat = rng.normal(0, 0.7, size=(1, 302, 80)).astype(np.float32)
    speaker = rng.normal(0, 0.4, size=(1, 192)).astype(np.float32)

    with torch.inference_mode():
        expected_values = reference(
            torch.from_numpy(tokens),
            torch.from_numpy(prompt_tokens),
            torch.from_numpy(prompt_feat),
            torch.from_numpy(speaker),
        )
        expected = {
            "mu": expected_values[0].cpu().numpy(),
            "spks": expected_values[1].cpu().numpy(),
            "cond": expected_values[2].cpu().numpy(),
        }

    model = ct.models.MLModel(
        str(args.coreml),
        compute_units=ct.ComputeUnit.CPU_ONLY,
    )
    observed = model.predict({
        "tokens": tokens,
        "prompt_tokens": prompt_tokens,
        "prompt_feat": prompt_feat,
        "speaker": speaker,
    })
    checks = [
        compare(name, expected[name], np.asarray(observed[name]))
        for name in ("mu", "spks", "cond")
    ]
    passed = all(row["pass"] for row in checks)
    receipt = {
        "schemaVersion": 2,
        "status": "PASS" if passed else "FAIL",
        "profile": "fixed225-reference151-mel302",
        "seed": 1986,
        "sourceCommit": "878940245562bcd1dd0231d78157ba78d70b39f6",
        "flowPtSha256": file_sha256(flow_pt),
        "coremlSha256": tree_sha256(args.coreml.resolve()),
        "referenceConstruction": "direct flow.pt conditioning weights + exact upstream PreLookaheadLayer/conditioning equations",
        "checks": checks,
        "environment": {
            "platform": platform.platform(),
            "coremltools": ct.__version__,
            "torch": torch.__version__,
        },
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt, indent=2))
    if not passed:
        raise SystemExit(2)


if __name__ == "__main__":
    main()

# Code purpose: dynamic Flow-condition Core ML parity without loading unrelated YAML objects.
# Upstream source: CausalMaskedDiffWithDiT + PreLookaheadLayer at CosyVoice3_NPU@878940245562bcd1dd0231d78157ba78d70b39f6.
# Generated: 2026-10-02 America/New_York.
