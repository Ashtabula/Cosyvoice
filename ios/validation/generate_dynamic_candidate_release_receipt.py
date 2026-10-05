#!/usr/bin/env python3
#@title generate_dynamic_candidate_release_receipt.py
# Requirement: generate a checklist-complete dynamic N1...479 Candidate release receipt only when current-source build, immutable private-RC fetch/replay, supported runtime rebuild convergence, physical cold/warm public-API benchmark, canonical Mac environment, human listening and N0 fail-closed policy all agree. License remains a Production gate.
from __future__ import annotations
import argparse,json,subprocess,time
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
REPO=ROOT.parent
PROFILE="ios-dynamic-n1-n479-reference"
VERSION="0.2.0-rc1"

def load(path:Path)->dict:
    if not path.is_file(): raise RuntimeError(f"missing evidence: {path}")
    value=json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value,dict): raise RuntimeError(f"JSON object required: {path}")
    return value

def require(value:bool,message:str)->None:
    if not value: raise RuntimeError(message)

def head()->str:
    return subprocess.check_output(["git","-C",str(REPO),"rev-parse","HEAD"],text=True).strip()

def runtime_unchanged(validated:str,current:str)->None:
    if subprocess.run(["git","-C",str(REPO),"diff","--quiet",validated,current,"--","ios/Package.swift","ios/Sources"]).returncode!=0:
        raise RuntimeError("shipping runtime differs from physically validated source commit")

def main()->int:
    p=argparse.ArgumentParser()
    p.add_argument("--build-receipt",type=Path,default=ROOT/"validation/evidence/dynamic_standalone_build.json")
    p.add_argument("--private-rc-receipt",type=Path,default=ROOT/"validation/evidence/dynamic_private_rc.json")
    p.add_argument("--rebuild-receipt",type=Path,default=ROOT/"validation/evidence/dynamic_runtime_rebuild.json")
    p.add_argument("--benchmark-receipt",type=Path,default=ROOT/"validation/evidence/dynamic_candidate_benchmark.json")
    p.add_argument("--environment-receipt",type=Path,default=ROOT/"validation/evidence/dynamic_release_environment.json")
    p.add_argument("--listening-receipt",type=Path,default=ROOT/"validation/evidence/dynamic_n1_listening_acceptance.json")
    p.add_argument("--n0-policy-receipt",type=Path,default=ROOT/"validation/evidence/dynamic_n0_policy.json")
    p.add_argument("--release-entry-receipt",type=Path,default=ROOT/"validation/dynamic_n1_release_entry_2026-10-04.json")
    p.add_argument("--output",type=Path,default=ROOT/"validation/dynamic_release_receipt.json")
    a=p.parse_args()

    current=head()
    subprocess.run(["python3",str(ROOT/"validation/audit_source_isolation.py")],check=True)

    build=load(a.build_receipt)
    private=load(a.private_rc_receipt)
    rebuild=load(a.rebuild_receipt)
    benchmark=load(a.benchmark_receipt)
    env=load(a.environment_receipt)
    listening=load(a.listening_receipt)
    n0=load(a.n0_policy_receipt)
    entry=load(a.release_entry_receipt)
    catalog=load(ROOT/"assets/releases.json")

    require(build.get("status")=="PASS_DYNAMIC_STANDALONE_BUILD","dynamic standalone build is not PASS")
    require(build.get("sourceCommit")==current,"standalone build is not current HEAD")
    require(private.get("status")=="PASS_DYNAMIC_PRIVATE_RC_IMMUTABLE_REPLAY","dynamic immutable private RC replay is not PASS")
    require(private.get("profile")==PROFILE and private.get("version")==VERSION,"dynamic private RC profile/version mismatch")
    require(private.get("ordinaryDeveloperFetchPass") is True and private.get("publicApiDefaultReplayPass") is True and private.get("publicApiReferenceReplayPass") is True,"dynamic private RC fetch/device replay incomplete")
    require(private.get("publicRedistributionApproved") is False,"dynamic Candidate must remain private before license approval")
    require(rebuild.get("status")=="PASS_SUPPORTED_DYNAMIC_RUNTIME_REBUILD_CONTRACT","dynamic runtime rebuild convergence is not PASS")
    require(rebuild.get("profile")==PROFILE and rebuild.get("NBounds")==[1,479],"dynamic rebuild profile/bounds mismatch")
    require(benchmark.get("status")=="PASS" and benchmark.get("benchmark")=="public-api-candidate-v1","dynamic Candidate benchmark is not PASS")
    require(benchmark.get("sourceCommit")==current,"dynamic Candidate benchmark is not current HEAD")
    require(benchmark.get("runtimeProfile")=="ios18-dynamic-n1-n479","dynamic Candidate benchmark runtime profile mismatch")
    require(benchmark.get("speechTokenBounds")==[1,479],"dynamic Candidate benchmark bounds mismatch")
    require((benchmark.get("measurement") or {}).get("flowSteps")==6,"dynamic Candidate benchmark does not use production flowSteps=6")
    require(env.get("status")=="PASS_RELEASE_ENVIRONMENT_RECORDED","release environment is not PASS")
    require(env.get("sourceCommit")==current,"release environment is not current HEAD")
    environment=env.get("environment") or {}
    for key in ("cleanRoomHost","releaseHost","toolchain","consumerRequirements","historicalAssetBuildProvenance"):
        require(bool(environment.get(key)),f"release environment missing {key}")
    require(listening.get("status")=="PASS_DYNAMIC_LISTENING_ACCEPTANCE","dynamic human listening is not PASS")
    require(n0.get("status")=="PASS_N0_FAIL_CLOSED_RELEASE_POLICY","N0 release policy is not PASS")
    require((n0.get("N0Policy") or {}).get("behavior")=="FAIL_CLOSED","N0 policy is not fail-closed")
    require(entry.get("status")=="PASS_DYNAMIC_N1_RELEASE_PROMOTION_ENTRY_NOT_PRODUCTION","dynamic release-entry evidence mismatch")

    releases=[r for r in catalog.get("releases",[]) if r.get("profile")==PROFILE and r.get("version")==VERSION]
    require(len(releases)==1,"dynamic immutable catalog row missing or ambiguous")
    release=releases[0]
    require(release.get("revision")==private.get("revision"),"catalog/private-RC immutable revision mismatch")
    require(release.get("payloadTreeSha256")==private.get("payloadTreeSha256"),"catalog/private-RC payload tree mismatch")
    require(release.get("testedRuntimeTreeSha256")==private.get("testedRuntimeTreeSha256"),"catalog/private-RC runtime tree mismatch")
    require(release.get("publicRedistributionApproved") is False,"catalog unexpectedly authorizes public redistribution")
    require(release.get("licenseGate")=="PENDING","dynamic Candidate license gate must remain PENDING until separate human review")
    asset=benchmark.get("asset") or {}
    for key in ("profile","version","repoId","revision","payloadTreeSha256","testedRuntimeTreeSha256"):
        require(asset.get(key)==release.get(key),f"benchmark asset {key} differs from immutable catalog")

    validated=str(private.get("validatedRuntimeSourceCommit") or "")
    require(len(validated)==40,"private RC validated runtime source commit missing")
    runtime_unchanged(validated,current)

    device=benchmark.get("device") or {}
    target=env.get("validationTarget") or {}
    require(device.get("modelIdentifier") and device.get("systemVersion"),"benchmark physical device identity incomplete")
    if target:
        require(target.get("modelIdentifier")==device.get("modelIdentifier"),"environment/benchmark physical device mismatch")
        require(target.get("systemVersion")==device.get("systemVersion"),"environment/benchmark OS mismatch")

    asset_identity=f"{release['profile']}/{release['version']}@{release['revision']}#{release['payloadTreeSha256']}"
    receipt={
        "schemaVersion":1,
        "engine":"CosyVoice3",
        "platform":"iOS",
        "releaseStatus":"candidate",
        "sourceCommit":current,
        "validatedRuntimeSourceCommit":validated,
        "assetIdentity":asset_identity,
        "profile":"ios18-dynamic-n1-n479",
        "speechTokenBounds":[1,479],
        "asset":{
            "profile":release["profile"],"version":release["version"],"repoId":release["repoId"],
            "revision":release["revision"],"payloadTreeSha256":release["payloadTreeSha256"],
            "testedRuntimeTreeSha256":release["testedRuntimeTreeSha256"],
            "visibility":"private","publicRedistributionApproved":False,"licenseGate":"PENDING"
        },
        "environment":environment,
        "device":{
            "model":device.get("model"),"modelIdentifier":device.get("modelIdentifier"),
            "soc":"Apple SoC implicit in physical iPhone model identifier",
            "os":f"iOS {device.get('systemVersion')}","systemVersion":device.get("systemVersion")
        },
        "checks":{
            "sourceIsolation":{"status":"PASS","evidence":["validation/audit_source_isolation.py","validation/evidence/dynamic_standalone_build.json","Package.swift"]},
            "standaloneBuild":{"status":"PASS","evidence":["validation/evidence/dynamic_standalone_build.json"]},
            "environmentRecorded":{"status":"PASS","evidence":["validation/evidence/dynamic_release_environment.json"]},
            "assetValidation":{"status":"PASS","evidence":["assets/releases.json","validation/evidence/dynamic_private_rc.json"]},
            "immutableFetchReplay":{"status":"PASS","evidence":["validation/evidence/dynamic_private_rc.json"]},
            "fullRuntimeRebuild":{"status":"PASS","evidence":["validation/evidence/dynamic_runtime_rebuild.json"]},
            "hostParity":{"status":"PASS","evidence":["validation/dynamic_n1_release_entry_2026-10-04.json"]},
            "targetRuntimeExecution":{"status":"PASS","evidence":["validation/evidence/dynamic_private_rc.json"]},
            "physicalDeviceExecution":{"status":"PASS","evidence":["validation/evidence/dynamic_private_rc.json","validation/evidence/dynamic_candidate_benchmark.json"]},
            "textToPcm":{"status":"PASS","evidence":["validation/evidence/dynamic_private_rc.json"]},
            "referenceConditionedPcm":{"status":"PASS","evidence":["validation/evidence/dynamic_private_rc.json","validation/evidence/dynamic_n1_listening_acceptance.json"]},
            "benchmarkRecorded":{"status":"PASS","evidence":["validation/evidence/dynamic_candidate_benchmark.json"]},
            "audioReview":{"status":"PASS","evidence":["validation/evidence/dynamic_n1_listening_acceptance.json"]},
            "n0FailClosedPolicy":{"status":"PASS","evidence":["validation/evidence/dynamic_n0_policy.json"]}
        },
        "runtime":{
            "flowSteps":{"default":6,"supported":[6,8,10]},
            "generationContract":"min(targetTextTokens*20,512-logicalPrefixLength)",
            "requestedComputePlacement":{
                "llmPrefill":"CPU_ONLY","llmDecode":"CPU_ONLY","dynamicAcoustic":"CPU_AND_NE","referenceEncoders":"CPU_ONLY",
                "residencyClaim":False
            },
            "dynamicAcousticExecutionHints":{"reshapeFrequency":"INFREQUENT"}
        },
        "accelerator":{"claim":"requested","evidence":["validation/evidence/dynamic_candidate_benchmark.json"],"note":"CPU_AND_NE is a requested Core ML compute-unit policy; no ANE residency claim is made."},
        "technicalDistributionReady":True,
        "publicRedistributionApproved":False,
        "productionReady":False,
        "productionPending":["cleanRoomIntegration","releaseTreeReproducible","licenseReview","publicIdentityReview","publicAssetPublication"],
        "recordedAtUnix":int(time.time())
    }
    a.output.parent.mkdir(parents=True,exist_ok=True)
    a.output.write_text(json.dumps(receipt,indent=2,sort_keys=True)+"\n",encoding="utf-8")
    print("[COSYVOICE3-DYNAMIC-CANDIDATE] PASS "+json.dumps(receipt,sort_keys=True),flush=True)
    return 0

if __name__=="__main__": raise SystemExit(main())

# Code purpose: checklist-complete dynamic N1...479 Candidate evidence ledger including the canonical environment block.
# Upstream source: current source build/isolation, immutable private RC, supported runtime rebuild, physical Candidate benchmark, human listening, N0 policy and canonical Mac environment receipts.
# Runtime environment: canonical macOS Apple-Silicon release checkout.
# Generated time: 2026-10-04 America/New_York.
# Changes: new dynamic Candidate generator; license remains a separate Production gate and public redistribution remains false.
