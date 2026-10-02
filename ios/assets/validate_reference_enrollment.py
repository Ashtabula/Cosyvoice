#!/usr/bin/env python3
# validate_reference_enrollment.py
# Requirement: validate the release-side reference enrollment asset contract without pretending unvalidated conversions are production-ready.
import argparse
import json
from pathlib import Path

REQUIRED = ("reference_enrollment.json",)

def main():
    p = argparse.ArgumentParser()
    p.add_argument("asset_root", type=Path)
    p.add_argument("--require-promoted", action="store_true")
    args = p.parse_args()
    root = args.asset_root.resolve()
    missing = [name for name in REQUIRED if not (root / name).is_file()]
    if missing:
        raise SystemExit("missing reference enrollment metadata: " + ", ".join(missing))
    data = json.loads((root / "reference_enrollment.json").read_text())
    checks = {
        "schemaVersion": data.get("schemaVersion") == 1,
        "profile": data.get("profile") == "cosyvoice3-reference-enrollment-v1",
        "speechTokenizerRate": data.get("sampleRates", {}).get("speechTokenizer") == 16000,
        "speakerEmbeddingRate": data.get("sampleRates", {}).get("speakerEmbedding") == 16000,
        "promptMelRate": data.get("sampleRates", {}).get("promptMel") == 24000,
        "speakerEmbeddingShape": data.get("expectedOutputs", {}).get("speakerEmbedding") == "float32[1,192]",
        "promptMelShape": data.get("expectedOutputs", {}).get("promptMel") == "float32[1,F,80]",
    }
    ok = all(checks.values())
    if args.require_promoted:
        ok = ok and data.get("status") == "PASS_DEVICE_PARITY"
    print(json.dumps({"status": "PASS" if ok else "FAIL", "checks": checks, "declaredStatus": data.get("status")}, indent=2))
    raise SystemExit(0 if ok else 2)

if __name__ == "__main__":
    main()

# Code purpose: release-gate the native reference-enrollment assets independently of the main fixed225 runtime.
# Upstream: frontend.py _extract_speech_token/_extract_spk_embedding/_extract_speech_feat.
# Runtime: Python3 build/validation host only.
# Generated: 2026-10-02 America/New_York.
