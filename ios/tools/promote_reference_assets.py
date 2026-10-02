#!/usr/bin/env python3
# Requirement: promote custom-reference assets only when host parity and physical-iPhone public-API smoke receipts are both PASS.
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


def load(path: Path) -> dict:
    return json.loads(path.read_text())


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--host-receipt", type=Path, required=True)
    parser.add_argument("--device-receipt", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    manifest = load(args.manifest)
    host = load(args.host_receipt)
    device = load(args.device_receipt)

    require(host.get("schemaVersion") == 2, "host receipt schema mismatch")
    require(host.get("status") == "PASS_HOST_PARITY", "host reference parity is not PASS")
    require(device.get("schemaVersion") == 1, "device receipt schema mismatch")
    require(device.get("status") == "PASS_DEVICE_PUBLIC_API_REFERENCE_PCM", "device custom-reference smoke is not PASS")
    require(device.get("sampleRate") == 24000, "device output sample rate mismatch")
    require(device.get("channels") == 1, "device output channel count mismatch")
    require(int(device.get("samples", 0)) > 0, "device output is empty")
    require(device.get("finite") is True, "device output contains NaN/Inf")
    host_sha256 = sha256(args.host_receipt)
    require(device.get("hostReceiptSha256") == host_sha256, "device receipt is not bound to this host parity receipt")

    reference = manifest.get("referenceEnrollment")
    require(isinstance(reference, dict), "manifest has no referenceEnrollment contract")
    require(reference.get("promptTokenCount") == 151, "promptTokenCount mismatch")
    require(reference.get("promptFrameCount") == 302, "promptFrameCount mismatch")

    reference["status"] = "PASS_DEVICE_PARITY"
    reference["promotionEvidence"] = {
        "hostReceiptSha256": host_sha256,
        "deviceReceiptSha256": sha256(args.device_receipt),
        "hostReceipt": args.host_receipt.name,
        "deviceReceipt": args.device_receipt.name,
    }
    manifest["referenceEnrollment"] = reference
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps({
        "status": "PASS_PROMOTED_MANIFEST_WRITTEN",
        "output": str(args.output),
        "referenceStatus": reference["status"],
        "evidence": reference["promotionEvidence"],
    }, indent=2))


if __name__ == "__main__":
    main()

# Code purpose: cryptographically bind promotion to host and device PASS receipts.
# Runtime: Python3 standard library.
# Generated: 2026-10-02 America/New_York.
