#!/usr/bin/env python3
# finalize_reference_device_promotion.py
# Requirement: promote the custom-reference lane only after a device PASS receipt is cryptographically bound to the current PASS_HOST_PARITY receipt.
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
from pathlib import Path


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def write(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(8 * 1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def replace_exact(text: str, old: str, new: str, label: str) -> str:
    require(old in text, f"expected checklist text missing: {label}")
    return text.replace(old, new, 1)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ios-root", type=Path, required=True)
    parser.add_argument("--asset-root", type=Path, required=True)
    parser.add_argument("--host-receipt", type=Path, required=True)
    parser.add_argument("--device-receipt", type=Path, required=True)
    parser.add_argument("--listening-acceptance", type=Path, required=True)
    parser.add_argument("--publication-head", required=True)
    args = parser.parse_args()

    ios_root = args.ios_root.resolve()
    asset_root = args.asset_root.resolve()
    host_receipt = args.host_receipt.resolve()
    device_receipt = args.device_receipt.resolve()
    listening_path = args.listening_acceptance.resolve()

    tracked_manifest_path = ios_root / "manifest.json"
    reference_contract_path = ios_root / "assets/reference_enrollment.json"
    checklist_path = ios_root / "RELEASE_CHECKLIST.md"
    development_receipt_path = ios_root / "validation/development_receipt.json"
    runtime_manifest_path = asset_root / "cosyvoice3_fixed225.json"
    evidence_dir = ios_root / "validation/reference-device"
    promoted_runtime_manifest = evidence_dir / "cosyvoice3_fixed225.promoted.json"
    tracked_device_receipt = evidence_dir / "reference-smoke-receipt.json"
    promotion_receipt_path = evidence_dir / "promotion-receipt.json"

    for path in (
        tracked_manifest_path,
        reference_contract_path,
        checklist_path,
        development_receipt_path,
        runtime_manifest_path,
        host_receipt,
        device_receipt,
        listening_path,
    ):
        require(path.exists(), f"required promotion input missing: {path}")

    host = load(host_receipt)
    device = load(device_receipt)
    listening = load(listening_path)

    require(host.get("schemaVersion") == 2, "host receipt schema mismatch")
    require(host.get("status") == "PASS_HOST_PARITY", "host receipt is not PASS_HOST_PARITY")
    require(device.get("schemaVersion") == 1, "device receipt schema mismatch")
    require(
        device.get("status") == "PASS_DEVICE_PUBLIC_API_REFERENCE_PCM",
        f"device receipt is not PASS: {device.get('status')}",
    )
    require(device.get("sampleRate") == 24000, "device sampleRate mismatch")
    require(device.get("channels") == 1, "device channel count mismatch")
    require(int(device.get("samples", 0)) > 0, "device PCM is empty")
    require(device.get("finite") is True, "device PCM contains NaN/Inf")
    require(float(device.get("peakAbs", 0.0)) > 1e-6, "device PCM is effectively silent by peak")
    require(float(device.get("rms", 0.0)) > 1e-7, "device PCM is effectively silent by RMS")

    host_hash = sha256(host_receipt)
    device_hash = sha256(device_receipt)
    require(
        device.get("hostReceiptSha256") == host_hash,
        "device receipt is not cryptographically bound to this host parity receipt",
    )
    require(
        listening.get("status") == "PASS_USER_LISTENING_ACCEPTANCE",
        "human listening acceptance is not PASS",
    )

    # Reuse the single asset-manifest promotion authority instead of duplicating
    # its reference contract validation here.
    promote_tool = ios_root / "tools/promote_reference_assets.py"
    command = [
        sys.executable,
        str(promote_tool),
        "--manifest", str(runtime_manifest_path),
        "--host-receipt", str(host_receipt),
        "--device-receipt", str(device_receipt),
        "--output", str(promoted_runtime_manifest),
    ]
    print("[COSYVOICE3-REFERENCE-PROMOTION] RUN " + " ".join(command), flush=True)
    subprocess.run(command, check=True)
    promoted = load(promoted_runtime_manifest)
    require(
        promoted.get("referenceEnrollment", {}).get("status") == "PASS_DEVICE_PARITY",
        "promoted runtime manifest did not reach PASS_DEVICE_PARITY",
    )
    shutil.copy2(promoted_runtime_manifest, runtime_manifest_path)

    tracked_manifest = load(tracked_manifest_path)
    tracked_manifest["publicApi"]["customReferencePromoted"] = True
    tracked_manifest["fixed225Profile"]["customReference"]["status"] = "PASS_DEVICE_PARITY"
    tracked_manifest["candidateBlockers"] = [
        item
        for item in tracked_manifest.get("candidateBlockers", [])
        if item != "physical-device custom-reference text-to-PCM"
    ]
    # Overall SDK status remains development until the unrelated release blockers
    # (hosted immutable assets, clean-room, benchmark, license review, etc.) close.
    tracked_manifest["releaseStatus"] = "development"
    tracked_manifest["shippingReady"] = False
    write(tracked_manifest_path, tracked_manifest)

    reference_contract = load(reference_contract_path)
    reference_contract["status"] = "PASS_DEVICE_PARITY"
    reference_contract["promotionEvidence"] = {
        "hostReceiptSha256": host_hash,
        "deviceReceiptSha256": device_hash,
        "deviceReceipt": "validation/reference-device/reference-smoke-receipt.json",
        "humanListeningAcceptance": "validation/reference-device/listening-acceptance.json",
        "publicationHeadAtPromotion": args.publication_head,
    }
    write(reference_contract_path, reference_contract)

    development = load(development_receipt_path)
    checks = development.setdefault("checks", {})
    checks["customReferenceRuntime"] = "PASS_HOST_AND_DEVICE_PARITY"
    checks["referenceAssetContract"] = "PASS_DEVICE_PARITY"
    checks["physicalDevicePublicApi"] = "PASS_DEVICE_PUBLIC_API_REFERENCE_PCM"
    checks["customReferenceParity"] = "PASS_HOST_PARITY_AND_DEVICE_PUBLIC_API"
    write(development_receipt_path, development)

    checklist = checklist_path.read_text(encoding="utf-8")
    checklist = replace_exact(
        checklist,
        "PASS: complete custom-reference host gate emitted `PASS_HOST_PARITY` with `HOST_PARITY_COMPLETE_DEVICE_PARITY_PENDING`.\n",
        "PASS: complete custom-reference host gate emitted `PASS_HOST_PARITY`.\n"
        "PASS: physical iPhone public API custom-reference smoke emitted accepted finite 24 kHz mono PCM and is cryptographically bound to the host parity receipt.\n"
        "PASS: user listening acceptance for the physical-device custom-reference output is recorded as `GOOD SOUND`.\n"
        "PASS: custom-reference lane is promoted to `PASS_DEVICE_PARITY`.\n",
        "host parity status",
    )
    checklist = checklist.replace(
        "BLOCKER: dynamic Flow-conditioning/custom-reference path has not yet passed physical-device public-API parity.\n",
        "",
    )
    checklist = checklist.replace(
        "BLOCKER: custom-reference public API has not yet produced accepted PCM on a physical iPhone from this publication tree.\n",
        "",
    )
    checklist_path.write_text(checklist, encoding="utf-8")

    evidence_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy2(device_receipt, tracked_device_receipt)

    promotion_receipt = {
        "schemaVersion": 1,
        "status": "PASS_CUSTOM_REFERENCE_DEVICE_PROMOTION",
        "scope": "CosyVoice3 iOS fixed225 custom-reference lane only",
        "overallReleaseStatus": "development",
        "publicationHeadAtPromotion": args.publication_head,
        "hostReceipt": {
            "status": host["status"],
            "sha256": host_hash,
        },
        "deviceReceipt": {
            "status": device["status"],
            "sha256": device_hash,
            "sampleRate": device["sampleRate"],
            "channels": device["channels"],
            "samples": device["samples"],
            "durationSeconds": device.get("durationSeconds"),
            "elapsedSeconds": device.get("elapsedSeconds"),
            "rtf": device.get("rtf"),
            "finite": device["finite"],
            "peakAbs": device.get("peakAbs"),
            "rms": device.get("rms"),
            "device": device.get("device"),
            "systemName": device.get("systemName"),
            "systemVersion": device.get("systemVersion"),
        },
        "hostDeviceBindingVerified": True,
        "humanListeningAcceptance": {
            "status": listening["status"],
            "userResponse": listening.get("userResponse"),
            "evidence": "validation/reference-device/listening-acceptance.json",
        },
        "runtimeManifest": {
            "path": str(runtime_manifest_path),
            "sha256": sha256(runtime_manifest_path),
            "referenceStatus": "PASS_DEVICE_PARITY",
        },
        "remainingOverallCandidateBlockers": tracked_manifest.get("candidateBlockers", []),
    }
    write(promotion_receipt_path, promotion_receipt)

    print(json.dumps({
        "status": promotion_receipt["status"],
        "referenceStatus": "PASS_DEVICE_PARITY",
        "overallReleaseStatus": "development",
        "deviceReceiptSha256": device_hash,
        "promotionReceipt": str(promotion_receipt_path),
        "remainingOverallCandidateBlockers": promotion_receipt["remainingOverallCandidateBlockers"],
    }, indent=2))


if __name__ == "__main__":
    main()

# Code purpose: finalize the custom-reference lane only after bound host/device machine receipts and separate human listening acceptance all pass.
# Runtime: macOS Python3 standard library; calls the existing promote_reference_assets.py authority.
# Generated: 2026-10-02 America/New_York.
