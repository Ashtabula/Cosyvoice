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
    candidate=load(ROOT/"validation/release_receipt.json"); base=load(ROOT/"validation/production_baseline.json"); clean=load(ROOT/"validation/evidence/production_clean_room.json"); tree=load(ROOT/"validation/evidence/release_tree_reproducible.json")
    dynamic=candidate.get("profile")=="ios18-dynamic-n1-n479"
    audio=load(ROOT/("validation/evidence/dynamic_n1_listening_acceptance.json" if dynamic else "validation/evidence/flow6_listening_acceptance.json"))
    if candidate.get("releaseStatus")!="candidate" or candidate.get("technicalDistributionReady") is not True or candidate.get("publicRedistributionApproved") is not False: raise RuntimeError("Candidate state mismatch")
    if candidate.get("validatedSourceCommit")!=base["validatedSourceCommit"] or candidate.get("assetIdentity")!=base["assetIdentity"]: raise RuntimeError("Candidate baseline binding mismatch")
    if subprocess.run(["git","-C",str(REPO),"diff","--quiet",base["candidateReleaseHead"],"HEAD","--","ios/Package.swift","ios/Sources"]).returncode!=0: raise RuntimeError("runtime source changed after Candidate baseline")
    if clean.get("status")!="PASS_PRODUCTION_CLEAN_ROOM" or clean.get("candidateReleaseHead")!=base["candidateReleaseHead"] or clean.get("assetIdentity")!=base["assetIdentity"] or clean.get("publicApiOnly") is not True: raise RuntimeError("Production clean-room evidence mismatch")
    if tree.get("status")!="PASS_RELEASE_TREE_REPRODUCIBLE" or tree.get("candidateReleaseHead")!=base["candidateReleaseHead"]: raise RuntimeError("release-tree reproducibility evidence mismatch")
    subprocess.run(["python3",str(ROOT/"validation/record_release_tree_reproducibility.py"),"--check-only","--expect-tree-sha256",tree["publicationTreeSha256"]],check=True)
    expected_audio="PASS_DYNAMIC_LISTENING_ACCEPTANCE" if dynamic else "PASS_USER_FLOW6_LISTENING_ACCEPTANCE"
    if audio.get("status")!=expected_audio: raise RuntimeError("human audio review evidence mismatch")
    if dynamic:
        n0=load(ROOT/"validation/evidence/dynamic_n0_policy.json")
        if n0.get("status")!="PASS_N0_FAIL_CLOSED_RELEASE_POLICY": raise RuntimeError("dynamic N0 release policy mismatch")
    print("[COSYVOICE3-PRODUCTION-PREFLIGHT] PASS_EXCEPT_LICENSE_IDENTITY_AND_PUBLICATION "+json.dumps({"candidateReleaseHead":base["candidateReleaseHead"],"profile":candidate.get("profile"),"passedChecks":["audioReview","cleanRoomIntegration","releaseTreeReproducible"]+(["n0FailClosedPolicy"] if dynamic else []),"pendingChecks":["licenseReview","publicIdentityReview","publicAssetPublication"],"publicRedistributionApproved":False},sort_keys=True),flush=True)
if __name__=="__main__": main()
# Code purpose: non-license/non-identity Production preflight; cannot mark Production or make assets public.
# Runtime environment: Python 3 standard library + Git.
# Generated time: 2026-10-03 America/New_York.

# Changes 2026-10-03: rerun deterministic current-tree verification against the committed publicationTreeSha256 so later evidence-only commits cannot hide public-snapshot drift.

# Changes 2026-10-04: select human-audio evidence from canonical Candidate profile; dynamic N1 additionally requires the explicit N0 fail-closed policy while fixed225 historical behavior remains supported.
