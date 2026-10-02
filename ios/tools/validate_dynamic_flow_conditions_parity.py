#!/usr/bin/env python3
# Requirement: prove the generic Core ML Flow-conditioning graph matches upstream PyTorch for the fixed225/151/302 profile.
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
from hyperpyyaml import load_hyperpyyaml


def tree_sha256(path: Path) -> str:
    h = hashlib.sha256()
    for file in sorted(p for p in path.rglob("*") if p.is_file()):
        h.update(str(file.relative_to(path)).encode())
        h.update(file.read_bytes())
    return h.hexdigest()


def compare(name: str, expected: np.ndarray, observed: np.ndarray, atol: float = 3e-4, rtol: float = 3e-4) -> dict:
    if expected.shape != observed.shape:
        return {"name": name, "pass": False, "shapeExpected": list(expected.shape), "shapeObserved": list(observed.shape)}
    diff = np.abs(expected.astype(np.float64) - observed.astype(np.float64))
    scale = np.maximum(np.abs(expected.astype(np.float64)), np.abs(observed.astype(np.float64)))
    passed = bool(np.isfinite(observed).all() and np.all(diff <= atol + rtol * scale))
    return {"name": name, "pass": passed, "maxAbs": float(diff.max(initial=0)), "meanAbs": float(diff.mean()), "atol": atol, "rtol": rtol}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--model-dir", type=Path, required=True)
    parser.add_argument("--coreml", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if platform.system() != "Darwin":
        raise RuntimeError("Core ML prediction parity must run on macOS")

    source_root = args.source_root.resolve()
    sys.path[:0] = [str(source_root), str(source_root / "third_party/Matcha-TTS")]
    model_dir = args.model_dir.resolve()
    with (model_dir / "cosyvoice3.yaml").open() as handle:
        cfg = load_hyperpyyaml(handle, overrides={"qwen_pretrain_path": str(model_dir / "CosyVoice-BlankEN")})
    flow = cfg["flow"].eval()
    flow.load_state_dict(torch.load(model_dir / "flow.pt", weights_only=True, map_location="cpu"), strict=True)

    rng = np.random.default_rng(1986)
    tokens = rng.integers(0, 6561, size=(1, 225), dtype=np.int32)
    prompt_tokens = rng.integers(0, 6561, size=(1, 151), dtype=np.int32)
    prompt_feat = rng.normal(0, 0.7, size=(1, 302, 80)).astype(np.float32)
    speaker = rng.normal(0, 0.4, size=(1, 192)).astype(np.float32)

    with torch.inference_mode():
        token_tensor = torch.from_numpy(tokens)
        prompt_token_tensor = torch.from_numpy(prompt_tokens)
        prompt_feat_tensor = torch.from_numpy(prompt_feat)
        speaker_tensor = torch.from_numpy(speaker)
        h = flow.pre_lookahead_layer(flow.input_embedding(torch.cat((prompt_token_tensor.long(), token_tensor.long()), dim=1)))
        h = h.repeat_interleave(2, dim=1).transpose(1, 2)
        spks = flow.spk_embed_affine_layer(torch.nn.functional.normalize(speaker_tensor, dim=1))
        cond = torch.nn.functional.pad(prompt_feat_tensor.transpose(1, 2), (0, 450))
        expected = {
            "mu": torch.cat((h, h * 0), dim=0).cpu().numpy(),
            "spks": torch.cat((spks, spks * 0), dim=0).cpu().numpy(),
            "cond": torch.cat((cond, cond * 0), dim=0).cpu().numpy(),
        }

    model = ct.models.MLModel(str(args.coreml), compute_units=ct.ComputeUnit.CPU_ONLY)
    observed = model.predict({
        "tokens": tokens,
        "prompt_tokens": prompt_tokens,
        "prompt_feat": prompt_feat,
        "speaker": speaker,
    })
    checks = [compare(name, expected[name], np.asarray(observed[name])) for name in ("mu", "spks", "cond")]
    passed = all(row["pass"] for row in checks)
    receipt = {
        "schemaVersion": 1,
        "status": "PASS" if passed else "FAIL",
        "profile": "fixed225-reference151-mel302",
        "seed": 1986,
        "coremlSha256": tree_sha256(args.coreml.resolve()),
        "checks": checks,
        "environment": {"platform": platform.platform(), "coremltools": ct.__version__, "torch": torch.__version__},
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt, indent=2))
    if not passed:
        raise SystemExit(2)


if __name__ == "__main__":
    main()

# Code purpose: generic Flow-conditioning numerical promotion gate.
# Upstream: CausalMaskedDiffWithDiT conditioning path at CosyVoice3_NPU@8789402.
# Generated: 2026-10-02 America/New_York.
