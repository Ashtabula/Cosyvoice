#!/usr/bin/env python3
#@title check_production_nonlicense.py
# Requirement: prove Candidate, audio review, physical clean-room integration and release-tree reproducibility while explicitly leaving license, public identity/snapshot and public asset publication unresolved.
from __future__ import annotations
import json,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]; REPO=ROOT.parent
def load(p): 
    if not p.is_file(): raise RuntimeError(f"missing Production evidence: {p}")
    return json.loads(p.read_text())
def main():
    candidate=load(ROOT/"validation/release_receipt.json"); base=load(ROOT/"validation/production_baseline.json"); clean=load(ROOT/"validation/evidence/production_clean_room.json"); tree=load(ROOT/"validation/evidence/release_tree_reproducible.json"); audio=load(ROOT/"validation/evidence/flow6_listening_acceptance.json")
    if candidate.get("releaseStatus")!="candidate" or candidate.get("technicalDistributionReady") is not True or candidate.get("publicRedistributionApproved") is not False: raise RuntimeError("Candidate state mismatch")
    if candidate.get("validatedSourceCommit")!=base["validatedSourceCommit"] or candidate.get("assetIdentity")!=base["assetIdentity"]: raise RuntimeError("Candidate baseline binding mismatch")
    if subprocess.run(["git","-C",str(REPO),"diff","--quiet",base["candidateReleaseHead"],"HEAD","--","ios/Package.swift","ios/Sources"]).returncode!=0: raise RuntimeError("runtime source changed after Candidate baseline")
    if clean.get("status")!="PASS_PRODUCTION_CLEAN_ROOM" or clean.get("candidateReleaseHead")!=base["candidateReleaseHead"] or clean.get("assetIdentity")!=base["assetIdentity"] or clean.get("publicApiOnly") is not True: raise RuntimeError("Production clean-room evidence mismatch")
    if tree.get("status")!="PASS_RELEASE_TREE_REPRODUCIBLE" or tree.get("candidateReleaseHead")!=base["candidateReleaseHead"]: raise RuntimeError("release-tree reproducibility evidence mismatch")
    if audio.get("status")!="PASS_USER_FLOW6_LISTENING_ACCEPTANCE": raise RuntimeError("human audio review evidence mismatch")
    print("[COSYVOICE3-PRODUCTION-PREFLIGHT] PASS_EXCEPT_LICENSE_IDENTITY_AND_PUBLICATION "+json.dumps({"candidateReleaseHead":base["candidateReleaseHead"],"passedChecks":["audioReview","cleanRoomIntegration","releaseTreeReproducible"],"pendingChecks":["licenseReview","publicIdentityReview","publicAssetPublication"],"publicRedistributionApproved":False},sort_keys=True),flush=True)
if __name__=="__main__": main()
# Code purpose: non-license/non-identity Production preflight; cannot mark Production or make assets public.
# Runtime environment: Python 3 standard library + Git.
# Generated time: 2026-10-03 America/New_York.
