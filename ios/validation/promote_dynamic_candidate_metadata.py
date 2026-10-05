#!/usr/bin/env python3
#@title promote_dynamic_candidate_metadata.py
# Requirement: after a checklist-complete dynamic Candidate receipt exists for the exact current source, promote dynamic N1...479 to the canonical private Candidate metadata authority while preserving fixed225 historical evidence. Never approve license/public redistribution or Production.
from __future__ import annotations
import argparse,json,subprocess
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
REPO=ROOT.parent
PROFILE="ios-dynamic-n1-n479-reference"
VERSION="0.2.0-rc1"

def load(path:Path)->dict:
    if not path.is_file(): raise RuntimeError(f"missing JSON: {path}")
    value=json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value,dict): raise RuntimeError(f"JSON object required: {path}")
    return value

def main()->int:
    p=argparse.ArgumentParser()
    p.add_argument("--receipt",type=Path,default=ROOT/"validation/dynamic_release_receipt.json")
    a=p.parse_args()
    receipt=load(a.receipt)
    current=subprocess.check_output(["git","-C",str(REPO),"rev-parse","HEAD"],text=True).strip()
    if receipt.get("releaseStatus")!="candidate" or receipt.get("technicalDistributionReady") is not True:
        raise RuntimeError("dynamic receipt is not Candidate")
    if receipt.get("sourceCommit")!=current:
        raise RuntimeError(f"dynamic Candidate receipt source {receipt.get('sourceCommit')} != current HEAD {current}")
    if receipt.get("publicRedistributionApproved") is not False or receipt.get("productionReady") is not False:
        raise RuntimeError("dynamic Candidate receipt exceeds private Candidate authority")
    if (receipt.get("asset") or {}).get("licenseGate")!="PENDING":
        raise RuntimeError("license is not expected to be approved by this non-license promotion")

    catalog_path=ROOT/"assets/releases.json"; catalog=load(catalog_path)
    matches=[r for r in catalog.get("releases",[]) if r.get("profile")==PROFILE and r.get("version")==VERSION]
    if len(matches)!=1: raise RuntimeError("dynamic release catalog row missing/ambiguous")
    row=matches[0]
    asset=receipt["asset"]
    for key in ("profile","version","repoId","revision","payloadTreeSha256","testedRuntimeTreeSha256"):
        if row.get(key)!=asset.get(key): raise RuntimeError(f"catalog/receipt {key} mismatch")
    row["candidateTechnicalDistributionReady"]=True
    row["technicalDistributionStatus"]="READY_PRIVATE_RC"
    row["sdkIntegrationReady"]=True
    row["sdkReleaseStatus"]="CANDIDATE_PRIVATE_ASSETS"
    row["publicReleaseStatus"]="PENDING_LICENSE_AND_PRODUCTION_GATES"
    row["publicRedistributionApproved"]=False
    row["licenseGate"]="PENDING"
    catalog["default"]={"profile":PROFILE,"version":VERSION}
    catalog_path.write_text(json.dumps(catalog,indent=2,sort_keys=True)+"\n",encoding="utf-8")

    historical=ROOT/"validation/history/fixed225_release_receipt.json"
    if not historical.is_file(): raise RuntimeError("historical fixed225 release receipt was not preserved")
    canonical=ROOT/"validation/release_receipt.json"
    canonical.write_text(json.dumps(receipt,indent=2,sort_keys=True)+"\n",encoding="utf-8")

    manifest_path=ROOT/"manifest.json"; manifest=load(manifest_path)
    manifest["schemaVersion"]=max(int(manifest.get("schemaVersion",0)),5)
    manifest["releaseStatus"]="candidate"
    manifest["releaseReadiness"]="Technical Distribution-Ready Candidate for dynamic N1...479 on immutable private RC; Production/public redistribution remains blocked by non-license Production gates plus separate license review."
    manifest["technicalDistributionReady"]=True
    manifest["sdkIntegrationReady"]=True
    manifest["shippingReady"]=False
    manifest["publicRedistributionApproved"]=False
    manifest["candidateBlockers"]=[]
    manifest["candidateReleaseReceipt"]="validation/release_receipt.json"
    manifest["historicalFixed225CandidateReceipt"]="validation/history/fixed225_release_receipt.json"
    manifest["dynamicProfile"]={
        "status":"CANDIDATE_PRIVATE_ASSETS",
        "runtimeProfile":"ios18-dynamic-n1-n479",
        "speechTokenBounds":[1,479],
        "flowFrameBounds":[304,1260],
        "melFrameBounds":[2,958],
        "pcmSampleBounds":[960,459840],
        "outputSampleRate":24000,
        "outputChannels":1,
        "flowSteps":{"default":6,"supported":[6,8,10]},
        "generationContract":"min(targetTextTokens*20,512-logicalPrefixLength)",
        "N0Policy":"FAIL_CLOSED_NON_PCM",
        "requestedComputePlacement":{
            "llmPrefill":"CPU_ONLY","llmDecode":"CPU_ONLY","dynamicAcoustic":"CPU_AND_NE","referenceEncoders":"CPU_ONLY",
            "residencyProven":False
        },
        "dynamicAcousticExecutionHints":{"reshapeFrequency":"INFREQUENT"},
        "customReference":{"status":"PASS_DEVICE_PARITY"},
        "validatedRuntimeSourceCommit":receipt.get("validatedRuntimeSourceCommit")
    }
    manifest["assetDistribution"]={
        "status":"PRIVATE_RC_IMMUTABLE_REPLAY_PASS",
        "profile":asset["profile"],"version":asset["version"],"repoId":asset["repoId"],
        "revision":asset["revision"],"payloadTreeSha256":asset["payloadTreeSha256"],
        "testedRuntimeTreeSha256":asset["testedRuntimeTreeSha256"],
        "requiresAuthentication":True,"publicRedistributionApproved":False,
        "licenseGate":"PENDING"
    }
    manifest["productionBlockers"]=[
        "clean-room consumer integration",
        "release-tree reproducibility",
        "asset redistribution license review",
        "public release identity review and fresh public snapshot",
        "immutable public runtime asset publication after clean-room and license approval"
    ]
    manifest_path.write_text(json.dumps(manifest,indent=2,sort_keys=True)+"\n",encoding="utf-8")

    print("[COSYVOICE3-DYNAMIC-PROMOTE] PASS canonical Candidate metadata now points to dynamic N1...479; fixed225 historical receipt preserved; license/public redistribution remain pending",flush=True)
    return 0

if __name__=="__main__": raise SystemExit(main())

# Code purpose: atomically switch private Candidate metadata authority from historical fixed225 to dynamic N1...479 after all technical Candidate gates pass.
# Upstream source: dynamic_release_receipt.json, immutable catalog row, historical fixed225 receipt, manifest.json.
# Runtime environment: release-engineering Python3 in the dynamic release checkout.
# Generated time: 2026-10-04 America/New_York.
# Changes: new non-license Candidate metadata promotion; never sets Production/public redistribution.
