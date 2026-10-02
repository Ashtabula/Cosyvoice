#@title audit_candidate_state.py
# Requirement: strict local audit of the post-transition Candidate metadata/evidence state before any commit or push.
from __future__ import annotations
import json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def load(path):
    if not path.is_file(): raise RuntimeError(f"missing Candidate file: {path}")
    return json.loads(path.read_text())
def main():
    manifest=load(ROOT/"manifest.json"); release=load(ROOT/"validation/release_receipt.json"); milestone=load(ROOT/"validation/ios_fixed225_distribution_ready_2026-10-02.json"); catalog=load(ROOT/"assets/releases.json"); checklist=(ROOT/"RELEASE_CHECKLIST.md").read_text()
    if manifest.get("releaseStatus")!="candidate" or manifest.get("technicalDistributionReady") is not True or manifest.get("sdkIntegrationReady") is not True or manifest.get("publicRedistributionApproved") is not False or manifest.get("candidateBlockers")!=[]: raise RuntimeError("manifest Candidate state mismatch")
    if release.get("releaseStatus")!="candidate" or release.get("technicalDistributionReady") is not True or release.get("publicRedistributionApproved") is not False or any(v.get("status")!="PASS" for v in release.get("checks",{}).values()): raise RuntimeError("release receipt Candidate state mismatch")
    if milestone.get("status")!="PASS" or milestone.get("releaseStatus")!="candidate" or milestone.get("technicalDistributionReady") is not True or milestone.get("publicRedistributionApproved") is not False: raise RuntimeError("distribution-ready milestone state mismatch")
    default=catalog.get("default") or {}; rows=[x for x in catalog.get("releases",[]) if x.get("profile")==default.get("profile") and x.get("version")==default.get("version")]
    if len(rows)!=1 or rows[0].get("candidateTechnicalDistributionReady") is not True or rows[0].get("publicRedistributionApproved") is not False: raise RuntimeError("asset catalog Candidate state mismatch")
    if "CANDIDATE BLOCKER:" in checklist: raise RuntimeError("Candidate blocker remains in release checklist")
    if "PRODUCTION BLOCKER:" not in checklist: raise RuntimeError("Production blockers unexpectedly absent")
    print("[COSYVOICE3-CANDIDATE-AUDIT] PASS releaseStatus=candidate technicalDistributionReady=true publicRedistributionApproved=false",flush=True)
if __name__=="__main__": main()
# Code purpose: prevent a partial or contradictory Candidate metadata commit after all non-license engineering gates pass.
# Upstream: manifest.json, assets/releases.json, validation/release_receipt.json, distribution-ready milestone receipt and RELEASE_CHECKLIST.md.
# Runtime: Python 3 standard library.
# Generated: 2026-10-02 America/New_York.
# Changes: new file; strict consistency audit for Candidate state while requiring Production blockers and public-redistribution=false to remain explicit.
