#!/usr/bin/env python3
# prepare_promoted_device_smoke_assets.py
# Requirement: stage an already-promoted complete runtime byte-for-byte into DeviceSmoke for immutable-HF replay without overwriting any runtime asset from local conversion candidates.
from __future__ import annotations

import argparse
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
    print("[COSYVOICE3-PROMOTED-DEVICE-ASSETS] RUN " + " ".join(values), flush=True)
    subprocess.run(values, check=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--asset-root", type=Path, required=True)
    parser.add_argument("--host-receipt", type=Path, required=True)
    parser.add_argument("--reference-wav", type=Path, required=True)
    parser.add_argument("--reference-transcript", type=Path, required=True)
    args = parser.parse_args()

    asset_root = args.asset_root.resolve()
    host_receipt = args.host_receipt.resolve()
    reference_wav = args.reference_wav.resolve()
    transcript = args.reference_transcript.resolve()

    run([sys.executable, VALIDATOR, "--root", asset_root, "--require-reference"])
    host = json.loads(host_receipt.read_text(encoding="utf-8"))
    if host.get("schemaVersion") != 2 or host.get("status") != "PASS_HOST_PARITY":
        raise RuntimeError("host receipt is not schema-2 PASS_HOST_PARITY")
    if not reference_wav.is_file():
        raise RuntimeError(f"reference WAV missing: {reference_wav}")
    if not transcript.is_file() or not transcript.read_text(encoding="utf-8").strip():
        raise RuntimeError(f"reference transcript missing/empty: {transcript}")

    if OUTPUT.exists():
        shutil.rmtree(OUTPUT)
    OUTPUT.mkdir(parents=True, exist_ok=True)
    (OUTPUT / ".gitkeep").write_text("", encoding="utf-8")
    shutil.copytree(asset_root, OUTPUT / "Runtime")
    shutil.copy2(reference_wav, OUTPUT / "reference.wav")
    shutil.copy2(transcript, OUTPUT / "reference.txt")
    shutil.copy2(host_receipt, OUTPUT / "reference_host_parity_receipt.json")

    run(
        [
            sys.executable,
            VALIDATOR,
            "--root",
            OUTPUT / "Runtime",
            "--require-reference",
        ]
    )
    print(
        f"[COSYVOICE3-PROMOTED-DEVICE-ASSETS] PASS runtime={asset_root} "
        "runtimeBytesPreserved=true localReferenceCandidatesApplied=false",
        flush=True,
    )


if __name__ == "__main__":
    main()

# Code purpose: stage an immutable fetched/promoted runtime for physical public-API replay without substituting local model assets.
# Runtime: macOS Python3 standard library.
# Generated: 2026-10-02 America/New_York.
