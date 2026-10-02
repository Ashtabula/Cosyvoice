#!/usr/bin/env python3
# Requirement: compare fixed-profile Core ML speech-tokenizer/CAMPPlus candidates against original ONNX graphs.
from __future__ import annotations

import argparse
import hashlib
import json
import platform
from pathlib import Path

import coremltools as ct
import numpy as np
import onnxruntime as ort


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    if path.is_file():
        h.update(path.read_bytes())
    else:
        for file in sorted(p for p in path.rglob("*") if p.is_file()):
            h.update(str(file.relative_to(path)).encode())
            h.update(file.read_bytes())
    return h.hexdigest()


def load_f32(path: Path, shape: tuple[int, ...]) -> np.ndarray:
    value = np.fromfile(path, dtype="<f4")
    if value.size != int(np.prod(shape)):
        raise RuntimeError(f"{path.name} float count {value.size} != {int(np.prod(shape))}")
    return value.reshape(shape)


def compare_float(name: str, expected: np.ndarray, observed: np.ndarray, atol: float, rtol: float) -> dict:
    if expected.shape != observed.shape:
        return {"name": name, "pass": False, "shapeExpected": list(expected.shape), "shapeObserved": list(observed.shape)}
    diff = np.abs(expected.astype(np.float64) - observed.astype(np.float64))
    maximum = float(diff.max(initial=0))
    mean = float(diff.mean()) if diff.size else 0.0
    scale = np.maximum(np.abs(expected.astype(np.float64)), np.abs(observed.astype(np.float64)))
    tolerance = atol + rtol * scale
    passed = bool(np.all(diff <= tolerance)) and bool(np.isfinite(observed).all())
    return {"name": name, "pass": passed, "maxAbs": maximum, "meanAbs": mean, "atol": atol, "rtol": rtol}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--upstream-model-dir", type=Path, required=True)
    parser.add_argument("--coreml-dir", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    if platform.system() != "Darwin":
        raise RuntimeError("Core ML prediction parity must run on macOS")

    fixture = args.fixture.resolve()
    upstream = args.upstream_model_dir.resolve()
    coreml_dir = args.coreml_dir.resolve()

    whisper = load_f32(fixture / "whisper128.f32", (1, 128, 605))
    camp_fbank = load_f32(fixture / "campplus_fbank.f32", (1, 604, 80))

    speech_onnx_path = upstream / "speech_tokenizer_v3.onnx"
    camp_onnx_path = upstream / "campplus.onnx"
    speech_session = ort.InferenceSession(str(speech_onnx_path), providers=["CPUExecutionProvider"])
    camp_session = ort.InferenceSession(str(camp_onnx_path), providers=["CPUExecutionProvider"])

    onnx_tokens = speech_session.run(None, {
        speech_session.get_inputs()[0].name: whisper,
        speech_session.get_inputs()[1].name: np.asarray([605], dtype=np.int32),
    })[0].reshape(-1)
    onnx_speaker = camp_session.run(None, {camp_session.get_inputs()[0].name: camp_fbank})[0]

    speech_ml_path = coreml_dir / "speech-tokenizer-fixed605.mlpackage"
    camp_ml_path = coreml_dir / "campplus-fixed604.mlpackage"
    speech_ml = ct.models.MLModel(str(speech_ml_path), compute_units=ct.ComputeUnit.CPU_ONLY)
    camp_ml = ct.models.MLModel(str(camp_ml_path), compute_units=ct.ComputeUnit.CPU_ONLY)
    ml_tokens = np.asarray(speech_ml.predict({"feats": whisper, "feats_length": np.asarray([605], dtype=np.int32)})["indices"]).reshape(-1)
    ml_speaker = np.asarray(camp_ml.predict({"input": camp_fbank})["output"])

    token_equal = bool(np.array_equal(onnx_tokens.astype(np.int64), ml_tokens.astype(np.int64)))
    speaker = compare_float("campplus", onnx_speaker, ml_speaker, atol=2e-4, rtol=2e-4)
    receipt = {
        "schemaVersion": 1,
        "status": "PASS" if token_equal and speaker["pass"] else "FAIL",
        "source": {
            "speechTokenizerOnnxSha256": sha256(speech_onnx_path),
            "campPlusOnnxSha256": sha256(camp_onnx_path),
            "speechTokenizerCoreMLSha256": sha256(speech_ml_path),
            "campPlusCoreMLSha256": sha256(camp_ml_path),
        },
        "speechTokenizer": {
            "pass": token_equal,
            "onnxCount": int(onnx_tokens.size),
            "coremlCount": int(ml_tokens.size),
            "mismatchCount": int(np.count_nonzero(onnx_tokens.astype(np.int64) != ml_tokens.astype(np.int64))) if onnx_tokens.shape == ml_tokens.shape else None,
        },
        "campPlus": speaker,
        "environment": {"platform": platform.platform(), "coremltools": ct.__version__, "onnxruntime": ort.__version__},
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt, indent=2))
    if receipt["status"] != "PASS":
        raise SystemExit(2)


if __name__ == "__main__":
    main()

# Code purpose: numerical promotion gate for learned reference-enrollment graphs.
# Runtime: macOS host with coremltools + onnxruntime.
# Generated: 2026-10-02 America/New_York.
