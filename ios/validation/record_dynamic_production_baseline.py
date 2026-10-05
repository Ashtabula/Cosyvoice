#!/usr/bin/env python3
#@title record_dynamic_production_baseline.py
# Requirement: freeze the exact promoted dynamic Candidate commit/source/asset/workload as the baseline for later Production clean-room and release-tree gates. This is evidence-only and does not mark Production.
from __future__ import annotations
import argparse,hashlib,json,subprocess
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
REPO=ROOT.parent

def load(path:Path)->dict:
    value=json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value,dict): raise RuntimeError(f"JSON object required: {path}")
    return value

def main()->int:
    p=argparse.ArgumentParser()
    p.add_argument("--candidate-release-head")
    p.add_argument("--output",type=Path,default=ROOT/"validation/production_baseline.json")
    a=p.parse_args()
    current=subprocess.check_output(["git","-C",str(REPO),"rev-parse","HEAD"],text=True).strip()
    candidate_head=a.candidate_release_head or current
    receipt=load(ROOT/"validation/release_receipt.json")
    benchmark=load(ROOT/"validation/evidence/dynamic_candidate_benchmark.json")
    if receipt.get("releaseStatus")!="candidate" or receipt.get("profile")!="ios18-dynamic-n1-n479":
        raise RuntimeError("canonical release receipt is not dynamic Candidate")
    if receipt.get("technicalDistributionReady") is not True or receipt.get("publicRedistributionApproved") is not False:
        raise RuntimeError("dynamic Candidate readiness state mismatch")
    if benchmark.get("status")!="PASS" or benchmark.get("sourceCommit")!=receipt.get("sourceCommit"):
        raise RuntimeError("dynamic Candidate benchmark/source binding mismatch")
    text=(benchmark.get("workload") or {}).get("text")
    if not text: raise RuntimeError("Candidate benchmark workload text missing")
    baseline={
        "schemaVersion":1,
        "status":"FROZEN_CANDIDATE_BASELINE",
        "engine":"CosyVoice3","platform":"iOS",
        "candidateReleaseHead":candidate_head,
        "baselineRecordedFromHead":current,
        "validatedSourceCommit":receipt["sourceCommit"],
        "validatedRuntimeSourceCommit":receipt.get("validatedRuntimeSourceCommit"),
        "runtimeSourcePaths":["ios/Package.swift","ios/Sources"],
        "assetIdentity":receipt["assetIdentity"],
        "profile":receipt["profile"],
        "speechTokenBounds":receipt["speechTokenBounds"],
        "publicRedistributionApproved":False,
        "candidateBenchmarkWorkload":{
            "text":text,
            "textSha256":hashlib.sha256(text.encode()).hexdigest(),
            "flowSteps":6,
            "speechTokenBounds":[1,479],
            "outputContract":"finite non-empty mono Float32 PCM at 24000 Hz; length is stochastic within validated dynamic envelope"
        }
    }
    a.output.parent.mkdir(parents=True,exist_ok=True)
    a.output.write_text(json.dumps(baseline,indent=2,sort_keys=True)+"\n",encoding="utf-8")
    print("[COSYVOICE3-DYNAMIC-BASELINE] PASS "+json.dumps(baseline,sort_keys=True),flush=True)
    return 0

if __name__=="__main__": raise SystemExit(main())

# Code purpose: freeze dynamic Candidate release head/source/asset/workload for later Production non-license gates.
# Upstream source: canonical dynamic validation/release_receipt.json and dynamic_candidate_benchmark.json.
# Runtime environment: release-engineering Python3 + Git.
# Generated time: 2026-10-04 America/New_York.
# Changes: new dynamic Production baseline recorder; no Production/public authorization.
