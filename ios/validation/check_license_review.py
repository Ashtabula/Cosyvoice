#!/usr/bin/env python3
#@title check_license_review.py
# Requirement: fail closed unless a human-reviewed PASS license receipt exists for the exact Candidate asset identity.
import json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
release=json.loads((ROOT/"validation/release_receipt.json").read_text()); path=ROOT/"validation/evidence/license_review.json"
if not path.is_file(): raise RuntimeError("license review receipt missing; public redistribution remains blocked")
x=json.loads(path.read_text())
if x.get("schemaVersion")!=1 or x.get("status")!="PASS_LICENSE_REVIEW" or x.get("assetIdentity")!=release.get("assetIdentity") or x.get("publicRedistributionApproved") is not True: raise RuntimeError("license review receipt does not approve the exact Candidate asset identity")
if not x.get("reviewedBy") or not x.get("reviewedAt") or not x.get("notices"): raise RuntimeError("license review receipt is incomplete")
print("[COSYVOICE3-LICENSE-REVIEW] PASS assetIdentity="+release["assetIdentity"],flush=True)
# Code purpose: human-license-decision verifier only; no automatic legal determination.
# Runtime environment: Python 3 standard library.
# Generated time: 2026-10-03 America/New_York.
