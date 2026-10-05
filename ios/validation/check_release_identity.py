#!/usr/bin/env python3
#@title check_release_identity.py
# Requirement: keep catalog default, canonical receipt, manifest and public provenance on one asset identity, and fail closed when shipping source changes without Candidate reclosure.
from __future__ import annotations
import json,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]; REPO=ROOT.parent
KEYS=("profile","version","repoId","revision","payloadTreeSha256","testedRuntimeTreeSha256")
def load(path):
    value=json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value,dict): raise RuntimeError(f"JSON object required: {path}")
    return value
def same(label,left,right):
    for key in KEYS:
        if left.get(key)!=right.get(key): raise RuntimeError(f"{label} {key} mismatch: {left.get(key)!r} != {right.get(key)!r}")
def main():
    catalog=load(ROOT/"assets/releases.json"); receipt=load(ROOT/"validation/release_receipt.json"); manifest=load(ROOT/"manifest.json"); provenance=load(ROOT/"PUBLIC_PROVENANCE.json")
    default=catalog.get("default") or {}; rows=[r for r in catalog.get("releases",[]) if r.get("profile")==default.get("profile") and r.get("version")==default.get("version")]
    if len(rows)!=1: raise RuntimeError("catalog default must resolve to exactly one release")
    release=rows[0]; same("receipt/catalog",receipt.get("asset") or {},release); same("manifest/catalog",manifest.get("assetDistribution") or {},release); same("provenance/catalog",provenance.get("asset") or {},release)
    if any(x.get("publicRedistributionApproved") is not False for x in [release,receipt,manifest,provenance]): raise RuntimeError("public redistribution must remain false before license/publication gates")
    validated=receipt.get("validatedSourceCommit")
    if not isinstance(validated,str) or len(validated)!=40: raise RuntimeError("canonical receipt validatedSourceCommit missing")
    changed=subprocess.run(["git","-C",str(REPO),"diff","--quiet",validated,"HEAD","--","ios/Package.swift","ios/Sources"]).returncode!=0
    flag=receipt.get("currentSourceReclosureRequired") is True
    if changed!=flag: raise RuntimeError(f"source/reclosure mismatch: runtimeChanged={changed} currentSourceReclosureRequired={flag}")
    if (manifest.get("currentSourceReclosureRequired") is True)!=flag or (provenance.get("currentSourceReclosureRequired") is True)!=flag: raise RuntimeError("reclosure flag differs across canonical metadata")
    expected_status="candidate-reclosure-required" if flag else "candidate"
    if receipt.get("releaseStatus")!=expected_status or manifest.get("releaseStatus")!=expected_status: raise RuntimeError("releaseStatus does not match reclosure state")
    if flag and receipt.get("technicalDistributionReady") is not False: raise RuntimeError("current source cannot remain technicalDistributionReady while reclosure is required")
    if not flag and receipt.get("technicalDistributionReady") is not True: raise RuntimeError("closed Candidate must be technicalDistributionReady")
    print("[COSYVOICE3-RELEASE-IDENTITY] PASS "+json.dumps({"asset":{k:release.get(k) for k in KEYS},"runtimeChangedSinceValidatedSource":changed,"currentSourceReclosureRequired":flag,"releaseStatus":expected_status},sort_keys=True),flush=True)
if __name__=="__main__": main()
# Code purpose: fail-closed canonical release identity and source-closure gate.
# Upstream: assets/releases.json, validation/release_receipt.json, manifest.json, PUBLIC_PROVENANCE.json.
# Runtime environment: Python 3 + Git; generated 2026-10-05 America/New_York.
