#@title generate_candidate_release_receipt.py
# Requirement: generate Candidate release_receipt.json only when current-branch build, supported full-runtime rebuild, immutable private-RC replay, physical-device PCM/promotion and controlled benchmark evidence all agree.
from __future__ import annotations
import argparse,json,subprocess,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def load(path):
    if not path.is_file(): raise RuntimeError(f"missing evidence: {path}")
    value=json.loads(path.read_text())
    if not isinstance(value,dict): raise RuntimeError(f"evidence is not JSON object: {path}")
    return value
def pass_check(name,value,expected="PASS"):
    if value!=expected: raise RuntimeError(f"{name} is {value!r}, expected {expected!r}")
def main():
    p=argparse.ArgumentParser(); p.add_argument("--build-receipt",type=Path,default=ROOT/"validation/evidence/standalone_build.json"); p.add_argument("--rebuild-receipt",type=Path,default=ROOT/"validation/evidence/full_runtime_rebuild.json"); p.add_argument("--benchmark-receipt",type=Path,default=ROOT/"validation/evidence/candidate_benchmark.json"); p.add_argument("--output",type=Path,default=ROOT/"validation/release_receipt.json"); a=p.parse_args()
    head=subprocess.check_output(["git","-C",str(ROOT.parent),"rev-parse","HEAD"],text=True).strip()
    build=load(a.build_receipt); rebuild=load(a.rebuild_receipt); benchmark=load(a.benchmark_receipt); promotion=load(ROOT/"validation/reference-device/promotion-receipt.json"); device=load(ROOT/"validation/reference-device/reference-smoke-receipt.json"); sdk=load(ROOT/"validation/ios_fixed225_sdk_ready_2026-10-02.json"); flow6_acceptance=load(ROOT/"validation/evidence/flow6_listening_acceptance.json"); catalog=load(ROOT/"assets/releases.json"); manifest=load(ROOT/"manifest.json")
    pass_check("standalone build",build.get("status")); pass_check("full runtime rebuild",rebuild.get("status"),"PASS_SUPPORTED_FULL_RUNTIME_REBUILD"); pass_check("candidate benchmark",benchmark.get("status")); pass_check("SDK integration milestone",sdk.get("status")); pass_check("device public API",device.get("status"),"PASS_DEVICE_PUBLIC_API_REFERENCE_PCM"); pass_check("custom reference promotion",promotion.get("status"),"PASS_CUSTOM_REFERENCE_DEVICE_PROMOTION")
    if (benchmark.get("measurement") or {}).get("flowSteps")!=6: raise RuntimeError("Candidate benchmark does not validate production default flowSteps=6")
    rebuild_semantics=rebuild.get("rebuildSemantics") or {}
    if rebuild_semantics.get("productionDefaultFlowSteps")!=6 or rebuild_semantics.get("validatedPublicFlowSteps")!=[6,8,10] or rebuild_semantics.get("flowParityFixtureSteps")!=10 or rebuild_semantics.get("flowParityFixtureRole")!="upstream-reference-parity-fixture": raise RuntimeError("full-runtime rebuild does not distinguish 10-step parity fixture from 6-step production default")
    h2h=flow6_acceptance.get("headToHead") or {}; selected=h2h.get("selectedVariant") or {}
    if flow6_acceptance.get("status")!="PASS_USER_FLOW6_LISTENING_ACCEPTANCE" or flow6_acceptance.get("decision")!="ACCEPT_FLOW6_AS_PRODUCTION_DEFAULT" or h2h.get("selectedFlowSteps")!=6: raise RuntimeError("6-step human listening acceptance is missing or does not select flowSteps=6")
    if h2h.get("hostReceiptSha256")!=promotion.get("hostReceipt",{}).get("sha256") or selected.get("wavSha256")!="f6b9633d96747ac6f36519c2fb3cc41f918c56b595251e4ef1265636a8eef2f5": raise RuntimeError("6-step listening evidence is not bound to the accepted head-to-head output")
    for name,value in (("build source",build.get("sourceCommit")),("rebuild publication",rebuild.get("publicationCommit")),("benchmark source",benchmark.get("sourceCommit"))):
        if value!=head: raise RuntimeError(f"{name} commit {value} != current HEAD {head}")
    if manifest.get("sdkIntegrationReady") is not True or manifest.get("publicRedistributionApproved") is not False:
        raise RuntimeError("manifest is not SDK-integration-ready/private")
    technical=manifest.get("technicalDistributionReady")
    if technical is False:
        pass
    elif technical is True:
        if manifest.get("releaseStatus")!="candidate" or manifest.get("candidateBlockers")!=[] or manifest.get("candidateReleaseReceipt")!="validation/release_receipt.json":
            raise RuntimeError("existing Candidate manifest is not a valid revalidation starting state")
    else:
        raise RuntimeError(f"unexpected technicalDistributionReady state: {technical!r}")
    default=catalog.get("default") or {}; rows=[r for r in catalog.get("releases",[]) if r.get("profile")==default.get("profile") and r.get("version")==default.get("version")]
    if len(rows)!=1: raise RuntimeError("release catalog default is not unique")
    release=rows[0]; asset=benchmark.get("asset") or {}; sdk_asset=sdk.get("assets") or {}
    for key in ("profile","version","repoId","revision","payloadTreeSha256","testedRuntimeTreeSha256"):
        if asset.get(key)!=release.get(key): raise RuntimeError(f"benchmark asset {key} differs from catalog")
        if sdk_asset.get(key)!=release.get(key): raise RuntimeError(f"SDK milestone asset {key} differs from catalog")
    if sdk.get("privateRcReplay",{}).get("status")!="PASS" or sdk.get("privateRcReplay",{}).get("ordinaryDeveloperFetchPass") is not True or sdk.get("privateRcReplay",{}).get("publicApiDeviceReplayPass") is not True: raise RuntimeError("immutable private-RC fetch/replay evidence is not PASS")
    if promotion.get("hostDeviceBindingVerified") is not True or promotion.get("humanListeningAcceptance",{}).get("status")!="PASS_USER_LISTENING_ACCEPTANCE": raise RuntimeError("promotion host/device/listening evidence incomplete")
    if benchmark.get("hostReceiptSha256")!=promotion.get("hostReceipt",{}).get("sha256"): raise RuntimeError("benchmark host binding differs from promoted device evidence")
    receipt={"schemaVersion":1,"engine":"CosyVoice3","platform":"iOS","releaseStatus":"candidate","sourceCommit":head,"validatedSourceCommit":head,"assetIdentity":f"{release['profile']}/{release['version']}@{release['revision']}#{release['payloadTreeSha256']}","asset":{"profile":release["profile"],"version":release["version"],"repoId":release["repoId"],"revision":release["revision"],"payloadTreeSha256":release["payloadTreeSha256"],"testedRuntimeTreeSha256":release["testedRuntimeTreeSha256"],"visibility":"private","publicRedistributionApproved":False},"device":{"model":benchmark["device"].get("model","iPhone"),"modelIdentifier":benchmark["device"]["modelIdentifier"],"os":f"iOS {benchmark['device']['systemVersion']}","systemVersion":benchmark["device"]["systemVersion"]},"checks":{"sourceIsolation":{"status":"PASS","evidence":["validation/evidence/standalone_build.json","Package.swift"]},"standaloneBuild":{"status":"PASS","evidence":["validation/evidence/standalone_build.json"]},"assetValidation":{"status":"PASS","evidence":["assets/releases.json","validation/ios_fixed225_sdk_ready_2026-10-02.json"]},"fullRuntimeRebuild":{"status":"PASS","evidence":["validation/evidence/full_runtime_rebuild.json"]},"hostParity":{"status":"PASS","evidence":["validation/reference-device/promotion-receipt.json"]},"targetRuntimeExecution":{"status":"PASS","evidence":["validation/reference-device/reference-smoke-receipt.json","validation/ios_fixed225_sdk_ready_2026-10-02.json"]},"physicalDeviceExecution":{"status":"PASS","evidence":["validation/reference-device/reference-smoke-receipt.json","validation/ios_fixed225_sdk_ready_2026-10-02.json"]},"textToPcm":{"status":"PASS","evidence":["validation/reference-device/reference-smoke-receipt.json"]},"immutableFetchReplay":{"status":"PASS","evidence":["validation/ios_fixed225_sdk_ready_2026-10-02.json"]},"benchmarkRecorded":{"status":"PASS","evidence":["validation/evidence/candidate_benchmark.json"]},"customReferenceDeviceParity":{"status":"PASS","evidence":["validation/reference-device/promotion-receipt.json"]},"flow6HumanListeningAcceptance":{"status":"PASS","evidence":["validation/evidence/flow6_listening_acceptance.json"]}},"accelerator":{"claim":"not-claimed","evidence":[]},"productionPending":["cleanRoomIntegration","releaseTreeReproducible","licenseReview","publicIdentityReview"],"technicalDistributionReady":True,"publicRedistributionApproved":False,"recordedAtUnix":int(time.time())}
    a.output.parent.mkdir(parents=True,exist_ok=True); a.output.write_text(json.dumps(receipt,indent=2,sort_keys=True)+"\n"); print("[COSYVOICE3-CANDIDATE-RECEIPT] PASS "+json.dumps(receipt,sort_keys=True),flush=True)
if __name__=="__main__": main()
# Code purpose: create the single machine-readable Candidate evidence ledger used to permit the technicalDistributionReady state transition.
# Upstream: current Swift build receipt, supported full-runtime rebuild receipt, immutable-RC SDK milestone, device/promotion receipts, controlled Candidate benchmark and committed asset catalog.
# Runtime: macOS Python 3 standard library inside the release checkout.
# Generated: 2026-10-02 America/New_York.
# Changes: new file; fail-closed commit/hash/status cross-checks and Candidate receipt generation while leaving Production clean-room/reproducibility/license gates pending.
# Changes 2026-10-02: permit strict full Candidate revalidation when the branch is already in a self-consistent private Candidate state; public redistribution must still be false and malformed partial Candidate state still fails closed.

# Changes 2026-10-03: Candidate release generation requires benchmark evidence for production default flowSteps=6.

# Changes 2026-10-03: Candidate generation now requires dedicated human listening acceptance for the exact 6-step head-to-head WAV, rather than inheriting the older 10-step promotion listening decision.

# Changes 2026-10-03: Candidate release generation requires rebuild evidence to distinguish the 10-step upstream parity fixture from production default 6 and public 6/8/10 choices.
# Changes 2026-10-03: align future Candidate receipts with canonical 检查单 fields: sourceCommit, assetIdentity, sourceIsolation, targetRuntimeExecution, normalized device fields, and publicIdentityReview as a Production gate.
