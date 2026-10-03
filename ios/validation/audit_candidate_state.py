#@title audit_candidate_state.py
# Requirement: strict local audit of the post-transition Candidate metadata/evidence state before any commit or push.
from __future__ import annotations
import json,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
ALLOWED_RELEASE_COMMIT_PATHS={
    "ios/manifest.json",
    "ios/assets/releases.json",
    "ios/RELEASE_CHECKLIST.md",
    "ios/BENCHMARK.md",
    "ios/README.md",
    "ios/SDK_RELEASE.md",
    "ios/API.md",
    "ios/ASSETS.md",
    "ios/validation/evidence/standalone_build.json",
    "ios/validation/evidence/full_runtime_rebuild.json",
    "ios/validation/evidence/candidate_benchmark.json",
    "ios/validation/release_receipt.json",
    "ios/validation/ios_fixed225_distribution_ready_2026-10-02.json",
    "ios/MILESTONES/IOS_FIXED225_DISTRIBUTION_READY_2026-10-02.md",
}
def load(path):
    if not path.is_file(): raise RuntimeError(f"missing Candidate file: {path}")
    return json.loads(path.read_text())
def main():
    manifest=load(ROOT/"manifest.json"); release=load(ROOT/"validation/release_receipt.json"); milestone=load(ROOT/"validation/ios_fixed225_distribution_ready_2026-10-02.json"); catalog=load(ROOT/"assets/releases.json"); checklist=(ROOT/"RELEASE_CHECKLIST.md").read_text()
    build=load(ROOT/"validation/evidence/standalone_build.json"); rebuild=load(ROOT/"validation/evidence/full_runtime_rebuild.json"); benchmark=load(ROOT/"validation/evidence/candidate_benchmark.json"); flow6_acceptance=load(ROOT/"validation/evidence/flow6_listening_acceptance.json")
    head=subprocess.check_output(["git","-C",str(ROOT.parent),"rev-parse","HEAD"],text=True).strip()
    if manifest.get("releaseStatus")!="candidate" or manifest.get("technicalDistributionReady") is not True or manifest.get("sdkIntegrationReady") is not True or manifest.get("publicRedistributionApproved") is not False or manifest.get("candidateBlockers")!=[]: raise RuntimeError("manifest Candidate state mismatch")
    public_api=manifest.get("publicApi") or {}; flow_contract=(manifest.get("fixed225Profile") or {}).get("flowSteps") or {}
    if public_api.get("userParameters")!=["reference","instruction","flowSteps"] or flow_contract.get("default")!=6 or flow_contract.get("supported")!=[6,8,10]: raise RuntimeError("manifest public Flow-step contract mismatch")
    if (benchmark.get("measurement") or {}).get("flowSteps")!=6: raise RuntimeError("Candidate benchmark does not validate production default flowSteps=6")
    if flow6_acceptance.get("status")!="PASS_USER_FLOW6_LISTENING_ACCEPTANCE" or (flow6_acceptance.get("headToHead") or {}).get("selectedFlowSteps")!=6: raise RuntimeError("6-step listening acceptance evidence mismatch")
    if release.get("releaseStatus")!="candidate" or release.get("technicalDistributionReady") is not True or release.get("publicRedistributionApproved") is not False or any(v.get("status")!="PASS" for v in release.get("checks",{}).values()): raise RuntimeError("release receipt Candidate state mismatch")
    if (release.get("checks") or {}).get("flow6HumanListeningAcceptance",{}).get("status")!="PASS": raise RuntimeError("Candidate release receipt omits 6-step human listening acceptance")
    validated=release.get("validatedSourceCommit")
    if not isinstance(validated,str) or len(validated)!=40: raise RuntimeError("Candidate receipt validatedSourceCommit missing/invalid")
    binding_mode="pre-commit"
    if validated!=head:
        parent_line=subprocess.check_output(["git","-C",str(ROOT.parent),"rev-list","--parents","-n","1",head],text=True).strip().split()
        if len(parent_line)!=2 or parent_line[1]!=validated:
            raise RuntimeError(f"Candidate receipt validates {validated} but current HEAD {head} is not that source commit or its single release-metadata child")
        changed=set(subprocess.check_output(["git","-C",str(ROOT.parent),"diff","--name-only",validated,head],text=True).splitlines())
        unexpected=sorted(changed-ALLOWED_RELEASE_COMMIT_PATHS)
        if unexpected: raise RuntimeError(f"release commit changes non-release paths: {unexpected}")
        binding_mode="release-commit"
    for name,value in (("standalone build",build.get("sourceCommit")),("full rebuild",rebuild.get("publicationCommit")),("candidate benchmark",benchmark.get("sourceCommit")),("milestone",milestone.get("validatedSourceCommit"))):
        if value!=validated: raise RuntimeError(f"{name} source binding {value!r} != validated source {validated}")
    if milestone.get("status")!="PASS" or milestone.get("releaseStatus")!="candidate" or milestone.get("technicalDistributionReady") is not True or milestone.get("publicRedistributionApproved") is not False: raise RuntimeError("distribution-ready milestone state mismatch")
    default=catalog.get("default") or {}; rows=[x for x in catalog.get("releases",[]) if x.get("profile")==default.get("profile") and x.get("version")==default.get("version")]
    if len(rows)!=1 or rows[0].get("candidateTechnicalDistributionReady") is not True or rows[0].get("publicRedistributionApproved") is not False: raise RuntimeError("asset catalog Candidate state mismatch")
    if "CANDIDATE BLOCKER:" in checklist: raise RuntimeError("Candidate blocker remains in release checklist")
    if "PRODUCTION BLOCKER:" not in checklist: raise RuntimeError("Production blockers unexpectedly absent")
    print(f"[COSYVOICE3-CANDIDATE-AUDIT] PASS bindingMode={binding_mode} validatedSourceCommit={validated} releaseHead={head} releaseStatus=candidate technicalDistributionReady=true publicRedistributionApproved=false",flush=True)
if __name__=="__main__": main()
# Code purpose: prevent a partial or contradictory Candidate metadata commit after all non-license engineering gates pass.
# Upstream: manifest.json, assets/releases.json, validation/release_receipt.json, distribution-ready milestone receipt and RELEASE_CHECKLIST.md.
# Runtime: Python 3 standard library.
# Generated: 2026-10-02 America/New_York.
# Changes: new file; strict consistency audit for Candidate state while requiring Production blockers and public-redistribution=false to remain explicit.
# Changes 2026-10-02: bind Candidate validity to the current Git HEAD so post-Candidate runtime changes cannot inherit stale release status without full revalidation.

# Changes 2026-10-03: Candidate audit requires manifest 6/8/10 public Flow metadata and committed benchmark evidence at the production 6-step default.

# Changes 2026-10-03: validatedSourceCommit now means the source/runtime commit; audit accepts either that pre-commit HEAD or one direct metadata/evidence-only release child, verifies all evidence binds to the validated parent, and rejects any runtime/source delta in the release commit.

# Changes 2026-10-03: Candidate audit requires the dedicated 6-step human listening acceptance evidence and its explicit PASS check in the release receipt.
