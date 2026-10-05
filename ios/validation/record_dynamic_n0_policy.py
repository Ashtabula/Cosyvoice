#!/usr/bin/env python3
#@title record_dynamic_n0_policy.py
# Requirement: record the dynamic release policy for the source-contract-valid immediate-EOS N0 case without changing EOS semantics. N0 must remain an explicit fail-closed non-PCM path: no padding, fake token, silent fallback or alternate engine.
from __future__ import annotations
import argparse,json,subprocess,time
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
REPO=ROOT.parent

def load(path:Path)->dict:
    if not path.is_file(): raise RuntimeError(f"missing evidence: {path}")
    value=json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value,dict): raise RuntimeError(f"JSON object required: {path}")
    return value

def main()->int:
    p=argparse.ArgumentParser()
    p.add_argument(
        "--lower-bound-receipt",type=Path,
        default=ROOT/"experiments/dynamic-acoustic/evidence/lower-bound-n1-extension-20261004-173341-20292/lower-bound-extension-receipt.json"
    )
    p.add_argument("--llm-sweep-receipt",type=Path)
    p.add_argument("--output",type=Path,default=ROOT/"validation/evidence/dynamic_n0_policy.json")
    a=p.parse_args()

    lower=load(a.lower_bound_receipt.expanduser().resolve())
    if lower.get("status")!="PASS_N1_N2_LOWER_BOUND_EXTENSION_NOT_PROMOTED":
        raise RuntimeError("lower-bound extension is not PASS")
    if lower.get("newNBounds")!=[1,479] or 0 not in lower.get("negativeBoundaryN",[]):
        raise RuntimeError("lower-bound evidence does not prove N0 is outside acoustic envelope")

    token_source=(ROOT/"Sources/CosyVoice3Core/CosyVoice3TokenSemantics.swift").read_text(encoding="utf-8")
    llm_source=(ROOT/"Sources/CosyVoice3Core/CosyVoice3LLMRuntime.swift").read_text(encoding="utf-8")
    acoustic_source=(ROOT/"Sources/CosyVoice3Core/CosyVoice3DynamicAcousticRuntime.swift").read_text(encoding="utf-8")
    if "static let eos = 6562" not in token_source or "static let sos = 6561" not in token_source:
        raise RuntimeError("EOS/SOS source semantics drifted")
    if "return decoded" not in llm_source or "CosyVoice3TokenSemantics.isStop(token)" not in llm_source:
        raise RuntimeError("LLM immediate-stop behavior not found")
    if "guard n >= contract.speechTokenMinimum" not in acoustic_source:
        raise RuntimeError("dynamic acoustic lower-bound fail-closed guard not found")

    sweep=None
    if a.llm_sweep_receipt:
        sweep=load(a.llm_sweep_receipt.expanduser().resolve())
        if not str(sweep.get("status","")).startswith(("PASS_","COMPLETE_")):
            raise RuntimeError("optional LLM sweep receipt is not complete/PASS")

    head=subprocess.check_output(["git","-C",str(REPO),"rev-parse","HEAD"],text=True).strip()
    observed=None
    if sweep:
        rows=[x for x in sweep.get("runs",[]) if x.get("status")=="PASS_RECORDED"]
        n0=sum(1 for x in rows if x.get("N")==0)
        observed={"successfulRuns":len(rows),"N0Runs":n0,"N0Rate":(n0/len(rows) if rows else None),"receipt":str(a.llm_sweep_receipt)}

    receipt={
        "schemaVersion":1,
        "status":"PASS_N0_FAIL_CLOSED_RELEASE_POLICY",
        "sourceCommit":head,
        "tokenSemantics":{"sos":6561,"eos":6562,"eosBehaviorChanged":False},
        "acousticSupportedNBounds":[1,479],
        "N0Policy":{
            "classification":"valid native-RAS immediate-EOS outcome outside successful acoustic PCM domain",
            "behavior":"FAIL_CLOSED",
            "successfulPcmClaim":False,
            "padOrInventSpeechToken":False,
            "suppressTrueEOS":False,
            "silentFallback":False,
            "alternateEngineFallback":False,
            "releaseMeaning":"N0 is a disclosed synthesis error path, not a successful audio result; successful synthesis remains required to return finite non-empty mono 24 kHz PCM."
        },
        "physicalBoundaryEvidence":{
            "status":lower["status"],
            "negativeBoundaryN":lower["negativeBoundaryN"],
            "newNBounds":lower["newNBounds"]
        },
        "incidenceEvidence":observed,
        "incidenceQuantificationRequiredForCandidate":False,
        "incidenceQuantificationNote":"A stochastic sweep can characterize frequency but cannot prove probability zero. Release correctness is defined by deterministic fail-closed handling without changing upstream EOS semantics.",
        "recordedAtUnix":int(time.time())
    }
    a.output.parent.mkdir(parents=True,exist_ok=True)
    a.output.write_text(json.dumps(receipt,indent=2,sort_keys=True)+"\n",encoding="utf-8")
    print("[COSYVOICE3-N0-POLICY] PASS "+json.dumps(receipt,sort_keys=True),flush=True)
    return 0

if __name__=="__main__": raise SystemExit(main())

# Code purpose: formalize N0 as an explicit fail-closed release edge while preserving native RAS/EOS semantics and successful-PCM contract.
# Upstream source: CosyVoice3 token semantics, LLM stop behavior, dynamic acoustic N1 lower-bound guard, physical N0 boundary rejection.
# Runtime environment: Python3 + Git; optional physical LLM sweep receipt may add incidence characterization.
# Generated time: 2026-10-04 America/New_York.
# Changes: new dynamic N0 release-policy gate; no runtime/model behavior change.
