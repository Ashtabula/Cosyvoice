#!/usr/bin/env python3
# validate_swift_reference_conditioning_parity.py
# Requirement: measure the actual fixed-profile iOS reference frontend at the Flow-conditioning boundary.
from __future__ import annotations

import argparse
import json
import platform
from pathlib import Path

import coremltools as ct
import numpy as np


def load_f32(path: Path, shape: tuple[int, ...]) -> np.ndarray:
    value = np.fromfile(path, dtype="<f4")
    expected = int(np.prod(shape))
    if value.size != expected:
        raise RuntimeError(f"{path.name} float count {value.size} != {expected}")
    return value.reshape(shape)


def compare_float(name: str, expected: np.ndarray, observed: np.ndarray, atol: float, rtol: float) -> dict:
    if expected.shape != observed.shape:
        return {
            "name": name,
            "pass": False,
            "shapeExpected": list(expected.shape),
            "shapeObserved": list(observed.shape),
        }
    expected64 = expected.astype(np.float64)
    observed64 = observed.astype(np.float64)
    diff = np.abs(expected64 - observed64)
    scale = np.maximum(np.abs(expected64), np.abs(observed64))
    tolerance = atol + rtol * scale
    return {
        "name": name,
        "pass": bool(np.isfinite(observed).all() and np.all(diff <= tolerance)),
        "maxAbs": float(diff.max(initial=0)),
        "meanAbs": float(diff.mean()) if diff.size else 0.0,
        "atol": atol,
        "rtol": rtol,
    }


def compare_distribution(
    name: str,
    expected: np.ndarray,
    observed: np.ndarray,
    *,
    max_tolerance: float,
    mean_tolerance: float,
    p99_tolerance: float,
) -> dict:
    if expected.shape != observed.shape:
        return {
            "name": name,
            "pass": False,
            "shapeExpected": list(expected.shape),
            "shapeObserved": list(observed.shape),
        }
    diff = np.abs(expected.astype(np.float64) - observed.astype(np.float64)).reshape(-1)
    finite = bool(np.isfinite(observed).all())
    maximum = float(diff.max(initial=0))
    mean = float(diff.mean()) if diff.size else 0.0
    p99 = float(np.quantile(diff, 0.99, method="higher")) if diff.size else 0.0
    passed = bool(
        finite
        and maximum <= max_tolerance
        and mean <= mean_tolerance
        and p99 <= p99_tolerance
    )
    return {
        "name": name,
        "pass": passed,
        "maxAbs": maximum,
        "meanAbs": mean,
        "p99Abs": p99,
        "maxTolerance": max_tolerance,
        "meanTolerance": mean_tolerance,
        "p99Tolerance": p99_tolerance,
        "finite": finite,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--coreml-dir", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--swift-whisper", type=Path, required=True)
    parser.add_argument("--swift-campplus-fbank", type=Path, required=True)
    parser.add_argument("--swift-prompt-mel", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    if platform.system() != "Darwin":
        raise RuntimeError("Core ML end-to-end reference parity must run on macOS")

    fixture = args.fixture.resolve()
    coreml_dir = args.coreml_dir.resolve()

    upstream_whisper = load_f32(fixture / "whisper128.f32", (1, 128, 605))
    upstream_fbank = load_f32(fixture / "campplus_fbank.f32", (1, 604, 80))
    upstream_prompt = load_f32(fixture / "prompt_mel.f32", (1, 302, 80))

    swift_whisper = load_f32(args.swift_whisper, (1, 128, 605))
    swift_fbank = load_f32(args.swift_campplus_fbank, (1, 604, 80))
    swift_prompt = load_f32(args.swift_prompt_mel, (1, 302, 80))

    speech = ct.models.MLModel(
        str(coreml_dir / "speech-tokenizer-fixed605.mlpackage"),
        compute_units=ct.ComputeUnit.CPU_ONLY,
    )
    camp = ct.models.MLModel(
        str(coreml_dir / "campplus-fixed604.mlpackage"),
        compute_units=ct.ComputeUnit.CPU_ONLY,
    )
    flow = ct.models.MLModel(
        str(coreml_dir / "flow-conditions-dynamic-151-302.mlpackage"),
        compute_units=ct.ComputeUnit.CPU_ONLY,
    )

    length = np.asarray([605], dtype=np.int32)
    upstream_tokens_full = np.asarray(
        speech.predict({"feats": upstream_whisper, "feats_length": length})["indices"]
    ).reshape(-1)
    swift_tokens_full = np.asarray(
        speech.predict({"feats": swift_whisper, "feats_length": length})["indices"]
    ).reshape(-1)

    if upstream_tokens_full.size < 151 or swift_tokens_full.size < 151:
        raise RuntimeError(
            f"speech tokenizer returned too few tokens: upstream={upstream_tokens_full.size} swift={swift_tokens_full.size}"
        )

    upstream_prompt_tokens = upstream_tokens_full[:151].astype(np.int32).reshape(1, 151)
    swift_prompt_tokens = swift_tokens_full[:151].astype(np.int32).reshape(1, 151)

    upstream_speaker = np.asarray(camp.predict({"input": upstream_fbank})["output"]).reshape(1, 192).astype(np.float32)
    swift_speaker = np.asarray(camp.predict({"input": swift_fbank})["output"]).reshape(1, 192).astype(np.float32)

    # Flow-condition mu also needs the 225 generated speech-token lane. Keep it
    # deterministic and identical so only reference preprocessing can move the result.
    rng = np.random.default_rng(1986)
    target_tokens = rng.integers(0, 6561, size=(1, 225), dtype=np.int32)

    upstream_flow = flow.predict({
        "tokens": target_tokens,
        "prompt_tokens": upstream_prompt_tokens,
        "prompt_feat": upstream_prompt,
        "speaker": upstream_speaker,
    })
    swift_flow = flow.predict({
        "tokens": target_tokens,
        "prompt_tokens": swift_prompt_tokens,
        "prompt_feat": swift_prompt,
        "speaker": swift_speaker,
    })

    prompt_token_equal = bool(np.array_equal(upstream_prompt_tokens, swift_prompt_tokens))
    checks = [
        {
            "name": "promptTokens151",
            "pass": prompt_token_equal,
            "mismatchCount": int(np.count_nonzero(upstream_prompt_tokens != swift_prompt_tokens)),
        },
        compare_float(
            "flowMu",
            np.asarray(upstream_flow["mu"]),
            np.asarray(swift_flow["mu"]),
            atol=3e-4,
            rtol=3e-4,
        ),
        compare_float(
            "flowSpks",
            np.asarray(upstream_flow["spks"]),
            np.asarray(swift_flow["spks"]),
            atol=3e-4,
            rtol=3e-4,
        ),
        # The conditioning graph only pads/duplicates prompt_feat. Therefore
        # flowCond inherits the same backend FFT drift already measured at
        # promptMel; use the same bounded max/mean/p99 criteria rather than
        # inventing a stricter per-element criterion at a no-op boundary.
        compare_distribution(
            "flowCond",
            np.asarray(upstream_flow["cond"]),
            np.asarray(swift_flow["cond"]),
            max_tolerance=8e-3,
            mean_tolerance=5e-4,
            p99_tolerance=3e-3,
        ),
    ]

    diagnostics = [
        compare_float(
            "speakerEmbedding192",
            upstream_speaker,
            swift_speaker,
            atol=3e-4,
            rtol=3e-4,
        ),
    ]

    receipt = {
        "schemaVersion": 2,
        "status": "PASS" if all(item["pass"] for item in checks) else "FAIL",
        "profile": "fixed225-reference151-mel302",
        "scope": "actual Swift reference DSP outputs propagated through shipping Core ML reference assets to the Flow-conditioning boundary",
        "checks": checks,
        "intermediateDiagnostics": diagnostics,
        "gatePolicy": {
            "authoritativeBoundary": ["promptTokens151", "flowMu", "flowSpks", "flowCond"],
            "speakerEmbedding192": "diagnostic intermediate; Flow consumes normalized+affine flowSpks",
            "flowCond": "same prompt-mel values after pad/duplicate; uses promptMel max/mean/p99 criteria",
        },
        "speechTokenizerCounts": {
            "upstream": int(upstream_tokens_full.size),
            "swift": int(swift_tokens_full.size),
            "consumedPromptTokens": 151,
        },
        "environment": {
            "platform": platform.platform(),
            "coremltools": ct.__version__,
        },
        "promotionEffect": "authoritative host-side reference-conditioning boundary gate; device parity remains separately required",
    }

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt, indent=2))
    if receipt["status"] != "PASS":
        raise SystemExit(2)


if __name__ == "__main__":
    main()

# Code purpose: authoritative host-side test of the native-reference frontend at the tensor boundary consumed by Flow; backend-sensitive intermediate DSP tensors remain separately recorded as guardrails/diagnostics.
# Upstream/reference baseline: deterministic Python fixture generated from the pinned CosyVoice3 source and pinned Matcha implementation.
# Runtime: macOS Core ML CPU validation host.
# Generated: 2026-10-02 America/New_York.
