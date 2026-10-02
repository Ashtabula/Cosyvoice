#!/usr/bin/env python3
# Requirement: stage a host-parity-approved custom-reference candidate into the public-API device-smoke app without mutating the canonical asset root.
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "validation/DeviceSmoke/GeneratedAssets"
VALIDATOR = ROOT / "assets/validate_assets.py"


def run(command: list[str | Path]) -> None:
    values = [str(value) for value in command]
    print("[COSYVOICE3-DEVICE-SMOKE-ASSETS] RUN " + " ".join(values), flush=True)
    subprocess.run(values, check=True)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--asset-root", type=Path, required=True)
    parser.add_argument("--host-receipt", type=Path, required=True)
    parser.add_argument("--reference-candidate-dir", type=Path, required=True)
    parser.add_argument("--reference-wav", type=Path, required=True)
    parser.add_argument("--reference-transcript", type=Path, required=True)
    parser.add_argument("--candidate-benchmark", action="store_true")
    args = parser.parse_args()

    asset_root = args.asset_root.resolve()
    host_receipt_path = args.host_receipt.resolve()
    reference_candidate_dir = args.reference_candidate_dir.resolve()
    reference_wav = args.reference_wav.resolve()
    transcript = args.reference_transcript.resolve()

    run([sys.executable, VALIDATOR, "--root", asset_root])
    host = json.loads(host_receipt_path.read_text())
    if host.get("schemaVersion") != 2 or host.get("status") != "PASS_HOST_PARITY":
        raise RuntimeError("host reference parity receipt is not schema-2 PASS_HOST_PARITY")
    if not reference_candidate_dir.is_dir():
        raise RuntimeError(f"reference candidate directory missing: {reference_candidate_dir}")
    if not reference_wav.is_file():
        raise RuntimeError(f"reference WAV missing: {reference_wav}")
    if not transcript.is_file() or not transcript.read_text(encoding="utf-8").strip():
        raise RuntimeError(f"reference transcript missing/empty: {transcript}")

    if OUTPUT.exists():
        shutil.rmtree(OUTPUT)
    OUTPUT.mkdir(parents=True, exist_ok=True)
    # GeneratedAssets/.gitkeep is a tracked repository placeholder. Recreate it
    # after replacing the staged tree so device validation never dirties tracked
    # source state merely by staging runtime assets.
    (OUTPUT / ".gitkeep").write_text("", encoding="utf-8")
    runtime = OUTPUT / "Runtime"
    shutil.copytree(asset_root, runtime)
    shutil.copy2(reference_wav, OUTPUT / "reference.wav")
    shutil.copy2(transcript, OUTPUT / "reference.txt")
    shutil.copy2(host_receipt_path, OUTPUT / "reference_host_parity_receipt.json")
    if args.candidate_benchmark:
        (OUTPUT / "candidate-benchmark-mode.json").write_text(json.dumps({"schemaVersion": 1, "benchmark": "public-api-candidate-v1"}, indent=2) + "\\n", encoding="utf-8")

    manifest_path = runtime / "cosyvoice3_fixed225.json"
    manifest = json.loads(manifest_path.read_text())
    reference = manifest.get("referenceEnrollment")
    if not isinstance(reference, dict):
        raise RuntimeError("manifest has no referenceEnrollment contract")

    candidate_sources = {
        "speechTokenizer": reference_candidate_dir / "speech-tokenizer-fixed605.mlpackage",
        "campPlus": reference_candidate_dir / "campplus-fixed604.mlpackage",
        "whisperMel128": reference_candidate_dir / "whisper_mel_128.f32",
        "kaldiMel80": reference_candidate_dir / "kaldi_mel_80.f32",
        "matchaMel80": reference_candidate_dir / "matcha_mel_80.f32",
        "flowConditionsDynamic": reference_candidate_dir / "flow-conditions-dynamic-151-302.mlpackage",
    }
    for key, source in candidate_sources.items():
        if not source.exists():
            raise RuntimeError(f"reference candidate missing: {source}")
        destination = runtime / reference[key]
        destination.parent.mkdir(parents=True, exist_ok=True)
        if destination.exists():
            if destination.is_dir():
                shutil.rmtree(destination)
            else:
                destination.unlink()
        if source.is_dir():
            shutil.copytree(source, destination)
        else:
            shutil.copy2(source, destination)
        print(
            f"[COSYVOICE3-DEVICE-SMOKE-ASSETS] STAGE {key} "
            f"source={source} destination={destination}",
            flush=True,
        )

    reference["status"] = "PASS_DEVICE_PARITY"
    reference["validationOverride"] = {
        "scope": "DEVICE_SMOKE_STAGED_COPY_ONLY",
        "hostReceiptSha256": sha256(host_receipt_path),
        "canonicalAssetRootMutated": False,
    }
    manifest["referenceEnrollment"] = reference
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")

    run([sys.executable, VALIDATOR, "--root", runtime, "--require-reference"])
    print(
        "[COSYVOICE3-DEVICE-SMOKE-ASSETS] PASS "
        f"output={OUTPUT} hostReceiptSha256={sha256(host_receipt_path)} "
        "canonicalAssetRootMutated=false",
        flush=True,
    )


if __name__ == "__main__":
    main()

# Code purpose: safe staged-copy activation for physical-device validation after host parity and before formal promotion; host-approved reference candidate assets are merged only into the staged copy and the tracked GeneratedAssets/.gitkeep placeholder is preserved.
# Runtime: macOS Python3 standard library.
# Generated: 2026-10-02 America/New_York.\n# Changes 2026-10-02: optional --candidate-benchmark writes a bundled benchmark-mode marker while keeping canonical source assets untouched.
