#!/usr/bin/env python3
#@title record_dynamic_standalone_build.py
# Requirement: prove the current CosyVoice3 iOS source is independently buildable/testable on the canonical Mac release host without Demo/other-engine source, run the source-isolation audit, and emit a source-commit-bound Candidate build receipt.
from __future__ import annotations
import argparse,json,platform,subprocess,time
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
REPO=ROOT.parent

def run(command:list[str],cwd:Path|None=None)->str:
    print("[COSYVOICE3-DYNAMIC-BUILD] RUN "+" ".join(command),flush=True)
    p=subprocess.run(command,cwd=cwd,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,check=False)
    print(p.stdout,end="" if p.stdout.endswith("\n") else "\n",flush=True)
    if p.returncode!=0: raise RuntimeError(f"command failed rc={p.returncode}: {' '.join(command)}")
    return p.stdout

def main()->int:
    ap=argparse.ArgumentParser()
    ap.add_argument("--output",type=Path,default=ROOT/"validation/evidence/dynamic_standalone_build.json")
    a=ap.parse_args()
    if platform.system()!="Darwin" or platform.machine()!="arm64":
        raise RuntimeError("Candidate build host must be macOS Apple Silicon")
    head=subprocess.check_output(["git","-C",str(REPO),"rev-parse","HEAD"],text=True).strip()
    run(["python3",str(ROOT/"validation/audit_source_isolation.py")],REPO)
    output=run(["swift","test","--package-path",str(ROOT)],REPO)
    receipt={
        "schemaVersion":1,
        "status":"PASS_DYNAMIC_STANDALONE_BUILD",
        "engine":"CosyVoice3","platform":"iOS",
        "sourceCommit":head,
        "package":"ios/Package.swift",
        "product":"CosyVoice3Core",
        "sourceIsolation":"PASS",
        "swiftTest":"PASS",
        "command":"swift test --package-path ios",
        "host":{"system":platform.system(),"architecture":platform.machine()},
        "outputTail":output[-4000:],
        "recordedAtUnix":int(time.time())
    }
    a.output.parent.mkdir(parents=True,exist_ok=True)
    a.output.write_text(json.dumps(receipt,indent=2,sort_keys=True)+"\n",encoding="utf-8")
    print("[COSYVOICE3-DYNAMIC-BUILD] PASS "+json.dumps(receipt,sort_keys=True),flush=True)
    return 0

if __name__=="__main__": raise SystemExit(main())

# Code purpose: current-source standalone/isolation/Swift-test evidence for the dynamic iOS Candidate.
# Upstream source: current ios/Package.swift, Sources, Tests and validation/audit_source_isolation.py.
# Runtime environment: canonical macOS Apple-Silicon release host.
# Generated time: 2026-10-04 America/New_York.
# Changes: new dynamic Candidate source-build receipt.
