#!/usr/bin/env python3
#@title generate_license_review_inventory.py
# Requirement: inventory the exact Candidate asset payload for human redistribution review without ever auto-approving licensing.
from __future__ import annotations
import argparse,json,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def main():
    p=argparse.ArgumentParser(); p.add_argument("--asset-root",type=Path,required=True); p.add_argument("--output",type=Path,default=ROOT/"validation/evidence/license_review_inventory.json"); a=p.parse_args()
    manifest=json.loads((a.asset_root/"asset-manifest.json").read_text()); release=json.loads((ROOT/"validation/release_receipt.json").read_text()); lock=json.loads((ROOT/"SOURCE_LOCK.json").read_text())
    if manifest.get("payloadTreeSha256")!=release["asset"]["payloadTreeSha256"]: raise RuntimeError("asset payload differs from Candidate release")
    rows=[{"path":x["path"],"bytes":int(x["bytes"]),"sha256":x["sha256"]} for x in manifest.get("files",[])]
    out={"schemaVersion":1,"status":"PENDING_HUMAN_LICENSE_REVIEW","assetIdentity":release["assetIdentity"],"sourceModel":lock["model"],"sourceRepository":{"repository":lock["developmentRepository"],"commit":lock["developmentCommit"]},"payloadTreeSha256":manifest["payloadTreeSha256"],"files":rows,"knownReviewFamilies":["CosyVoice/CosyVoice3 source","Qwen-derived LLM weights","speech_tokenizer_v3","CAMPPlus","Flow/DiT","HiFT","tokenizer/frontend tables"],"requiredDecision":"A human reviewer must verify redistribution/commercial/attribution terms and notices for the exact payload before creating validation/evidence/license_review.json with PASS_LICENSE_REVIEW.","recordedAtUnix":int(time.time())}
    a.output.parent.mkdir(parents=True,exist_ok=True); a.output.write_text(json.dumps(out,indent=2,sort_keys=True)+"\n"); print("[COSYVOICE3-LICENSE-INVENTORY] PENDING "+json.dumps({"assetIdentity":out["assetIdentity"],"fileCount":len(rows)},sort_keys=True),flush=True)
if __name__=="__main__": main()
# Code purpose: exact asset-file inventory for human license review; deliberately incapable of approving redistribution.
# Runtime environment: Python 3 standard library.
# Generated time: 2026-10-03 America/New_York.
