#!/usr/bin/env python3
# prepare_fixed449_performance_runtime.py
# Requirement: create a diagnostic-only runtime override by replacing only the immutable RC's fixed512 decode package with the already validated fixed449 mask-write candidate; never emit Candidate/release evidence from this modified tree.
from __future__ import annotations
import argparse,hashlib,json,shutil
from pathlib import Path

def tree_sha256(path:Path)->str:
    h=hashlib.sha256()
    for item in sorted(p for p in path.rglob("*") if p.is_file()):
        h.update(str(item.relative_to(path)).encode())
        h.update(item.read_bytes())
    return h.hexdigest()

def main()->None:
    p=argparse.ArgumentParser()
    p.add_argument("--runtime",type=Path,required=True)
    p.add_argument("--decode449",type=Path,required=True)
    a=p.parse_args()
    root=a.runtime.resolve()
    source=a.decode449.resolve()
    manifest_path=root/"cosyvoice3_fixed225.json"
    if not manifest_path.is_file(): raise RuntimeError(f"runtime manifest missing: {manifest_path}")
    if not source.is_dir(): raise RuntimeError(f"fixed449 package missing: {source}")
    manifest=json.loads(manifest_path.read_text())
    if manifest.get("profile")!="ios18-fixed225": raise RuntimeError("fixed449 override is allowed only for ios18-fixed225")
    old=manifest.get("llmDecode")
    if old!="models/llm-opt-perlayer-decode-maskwrite512.mlpackage":
        raise RuntimeError(f"unexpected source decode path: {old!r}")
    destination=root/"models/llm-opt-perlayer-decode-maskwrite449.mlpackage"
    old_path=root/old
    if old_path.exists(): shutil.rmtree(old_path)
    if destination.exists(): shutil.rmtree(destination)
    shutil.copytree(source,destination)
    manifest["llmDecode"]="models/llm-opt-perlayer-decode-maskwrite449.mlpackage"
    manifest_path.write_text(json.dumps(manifest,indent=2)+"\n")
    receipt={
        "schemaVersion":1,
        "status":"DIAGNOSTIC_FIXED449_OVERRIDE",
        "releaseEvidenceAllowed":False,
        "sourceProfile":"ios18-fixed225",
        "originalDecode":"models/llm-opt-perlayer-decode-maskwrite512.mlpackage",
        "overrideDecode":manifest["llmDecode"],
        "overrideSource":str(source),
        "overrideTreeSha256":tree_sha256(source),
        "scope":"performance A/B only; immutable HF asset-manifest intentionally remains the RC1 identity and must not be used to certify this modified runtime",
    }
    (root/"performance-fixed449-override.json").write_text(json.dumps(receipt,indent=2,sort_keys=True)+"\n")
    print("[COSYVOICE3-PERF-449] PASS "+json.dumps(receipt,sort_keys=True),flush=True)

if __name__=="__main__":
    main()

# Code purpose: stage the previously device/audio-accepted <=449 mask-write decode as a local performance-only A/B override without mutating or mislabeling the immutable RC.
# Upstream candidate: CosyVoice3_NPU iOS/converted/llm_fp16/llm-opt-perlayer-decode-maskwrite449.mlpackage and its accepted physical-device/audio receipts.
# Runtime: macOS Python3 standard library.
# Generated: 2026-10-02 America/New_York.
