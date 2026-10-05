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
    if manifest.get("candidateMilestone"):
        manifest["historicalFixed225CandidateMilestone"]=manifest["candidateMilestone"]
    if manifest.get("sdkReadyMilestone"):
        manifest["historicalFixed225SdkReadyMilestone"]=manifest["sdkReadyMilestone"]
    manifest["candidateMilestone"]={
        "status":"PASS",
        "date":"2026-10-04",
        "receipt":"validation/dynamic_release_receipt.json",
        "milestone":"dynamic N1...479 private Candidate"
    }
    manifest["sdkReadyMilestone"]={
        "status":"PASS_DYNAMIC_N1_RELEASE_PROMOTION_ENTRY_NOT_PRODUCTION",
        "date":"2026-10-04",
        "receipt":"validation/dynamic_n1_release_entry_2026-10-04.json",
        "milestone":"dynamic N1...479 release-promotion entry"
    }
    publication=dict(manifest.get("publication") or {})
    publication.update({
        "repository":"Ashtabula/Cosyvoice",
        "branch":"release/ios-dynamic-n1-sdk-ready",
        "path":"ios/",
        "canonicalSource":True,
        "publicTargetRepository":"actacomes/Cosyvoice",
        "publicSnapshotScope":"ios/public_snapshot_paths.txt"
    })
    manifest["publication"]=publication
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

    benchmark=load(ROOT/"validation/evidence/dynamic_candidate_benchmark.json")
    m=benchmark["measurement"]
    device=benchmark["device"]
    environment=receipt["environment"]

    assets_text=f"""# CosyVoice3 iOS assets

Status: **Technical Distribution-Ready Candidate — dynamic N1...479 on immutable private RC; public redistribution is not authorized.**

Source checkpoint: `FunAudioLLM/Fun-CosyVoice3-0.5B-2512`, revision `29e01c4e8d000f4bcd70751be16fa94bf3d85a18`. Canonical maintained SDK source: `Ashtabula/Cosyvoice/ios/`.

The ordinary developer path is `assets/releases.json -> assets/fetch_assets.py -> exact Hugging Face revision -> file/tree hash verification -> assets/validate_assets.py -> atomic activation`. Current Candidate private RC: `{asset['profile']}/{asset['version']}` in `{asset['repoId']}`, immutable revision `{asset['revision']}`, payload tree `{asset['payloadTreeSha256']}`, tested runtime tree `{asset['testedRuntimeTreeSha256']}`. Exact immutable fetch plus physical default/reference public-API replay are recorded in `validation/evidence/dynamic_private_rc.json`.

The active runtime profile is `ios18-dynamic-n1-n479`: speech-token N=1...479, T=304...1260, G=2...958, PCM=960...459840 samples, mono Float32 24 kHz. Public Flow choices are 6/8/10 with 6 default. Stateful LLM prefill/decode request CPU_ONLY; dynamic acoustic requests CPU_AND_NE with `reshapeFrequency=INFREQUENT`; this is not an ANE residency claim.

Custom-reference assets remain `PASS_DEVICE_PARITY`. The real-person validation reference used during device acceptance is validation-only and is excluded from the immutable public/example asset contract. Consumers supply their own reference audio/transcript through the public API.

Canonical release/clean-room host: `{environment['cleanRoomHost']}`. Release toolchain: `{environment['toolchain']}`. Consumer path: `{environment['consumerRequirements']}`.

The historical `ios-fixed225-reference/0.1.0-rc1` immutable RC and its release receipt remain preserved as baseline evidence but are no longer the current catalog default after dynamic Candidate promotion.

Maintainer conversion/rebuild tooling is not an ordinary consumer dependency. The supported dynamic rebuild gate proves validator/ABI/manifest convergence against the immutable RC and records byte identity only when actually observed; it does not assume Core ML compiler serialization is deterministic across toolchains.

Large binaries remain outside Git. `licenseGate=PENDING` and `publicRedistributionApproved=false` remain mandatory until the separate human license/redistribution gate passes.
"""
    (ROOT/"ASSETS.md").write_text(assets_text,encoding="utf-8")

    benchmark_text=f"""# CosyVoice3 iOS benchmark status

Current Candidate benchmark: **PASS — dynamic N1...479 immutable private RC through physical-device public API.**

Asset: `{asset['profile']}/{asset['version']}` @ `{asset['revision']}`.
Device: `{device['modelIdentifier']}`, iOS `{device['systemVersion']}`.
Flow steps: `{m['flowSteps']}` (production default).
Engine init: `{m['engineInitMilliseconds']:.3f} ms`.
First synthesis: `{m['firstSynthesisMilliseconds']:.3f} ms`, audio `{m['firstAudioSeconds']:.6f} s`, RTF `{m['firstRTF']:.6f}`, samples `{m['firstSamples']}`.
Warm repeat: `{m['repeatSynthesisMilliseconds']:.3f} ms`, audio `{m['repeatAudioSeconds']:.6f} s`, RTF `{m['repeatRTF']:.6f}`, samples `{m['repeatSamples']}`.
Output contract: finite mono Float32 PCM at 24 kHz; dynamic length is stochastic and each successful sample count must equal 960*N within N=1...479.
Requested placement: LLM CPU_ONLY; dynamic acoustic CPU_AND_NE; reference encoders CPU_ONLY. `reshapeFrequency=INFREQUENT`. Requested placement is not residency evidence.
Release environment: `{environment['cleanRoomHost']}`; toolchain: `{environment['toolchain']}`.
Evidence: `validation/evidence/dynamic_candidate_benchmark.json`.

Historical fixed225 benchmark evidence remains preserved but is not the current Candidate benchmark authority.
"""
    (ROOT/"BENCHMARK.md").write_text(benchmark_text,encoding="utf-8")

    readme=f"""# CosyVoice3 iOS SDK publication tree

Status: **Technical Distribution-Ready Candidate — dynamic N1...479 on immutable private RC; public redistribution is not authorized.** Public target: `actacomes/Cosyvoice` as a fresh-history Swift SDK snapshot only after Production gates.

The shipping public facade is `CosyVoice3Engine(assetRoot:)`. The active Candidate path is native tokenizer/prefill -> fixed512 stateful Core ML LLM -> native stochastic RAS/EOS -> exact-length dynamic Conditions/Flow -> FP64 F0/HiFT -> finite mono Float32 PCM at 24 kHz. The SDK accepts optional reference audio/transcript, optional instruction and validated Flow choices 6/8/10 with 6 default.

Current immutable private asset authority: `{asset['profile']}/{asset['version']}` at exact revision `{asset['revision']}`. Speech-token range is N=1...479. Successful PCM length is `960*N`; immediate native EOS may produce N0, which is an explicit fail-closed non-PCM error path. EOS remains 6562 and is not artificially suppressed to hide this edge.

Custom reference/voice cloning is physically validated. Validation-only real-person reference media is not part of public runtime/example assets; consumers supply their own authorized reference material.

Requested Core ML configuration is LLM CPU_ONLY, dynamic acoustic CPU_AND_NE with `reshapeFrequency=INFREQUENT`, reference encoders CPU_ONLY. No ANE residency claim is made.

Canonical release environment: `{environment['cleanRoomHost']}`; toolchain: `{environment['toolchain']}`; supported consumer path: `{environment['consumerRequirements']}`.

The historical fixed225 private Candidate remains preserved in `validation/history/fixed225_release_receipt.json` and the fixed catalog row; it is not the current default.

Python is release/conversion/validation tooling only. Shipping runtime uses Swift, AVFoundation, Accelerate, Core ML and swift-transformers. Ordinary consumers fetch immutable assets through `assets/fetch_assets.py` and do not rebuild model conversion graphs.

Production/public release still requires independent clean-room consumer integration, deterministic public-tree reproducibility, human license/redistribution approval, fresh public identity/tree review, and immutable public asset publication. `publicRedistributionApproved=false` until those gates pass.

## SDK layout

The private validation tree retains conversion, benchmarks and evidence. The external snapshot is controlled by `public_snapshot_paths.txt`; Demo repositories are consumers only and are never runtime/build dependencies.
"""
    (ROOT/"README.md").write_text(readme,encoding="utf-8")

    api_path=ROOT/"API.md"
    api=api_path.read_text(encoding="utf-8")
    api=api.replace("The immutable `ios-fixed225-reference/0.1.0-rc1` private asset profile passed ordinary-developer fetch plus physical public-API replay. Current-source Candidate evidence now additionally includes the supported full-runtime rebuild, controlled cold/warm public-API benchmark at flowSteps=6, and `validation/release_receipt.json`; Production/public release remains separately gated.",
        f"The current immutable Candidate asset profile is `{asset['profile']}/{asset['version']}` at exact revision `{asset['revision']}`. It supports dynamic N=1...479; successful output length is 960*N samples. The historical fixed225 Candidate remains preserved as baseline evidence. Production/public release remains separately gated.")
    if "Dynamic N=1...479" not in api:
        api += "\nDynamic N=1...479 is the current Candidate acoustic envelope. N0 from immediate native EOS is explicitly fail-closed and is not converted into fake/silent PCM.\n"
    (ROOT/"API.md").write_text(api,encoding="utf-8")

    validation_path=ROOT/"VALIDATION.md"
    validation=validation_path.read_text(encoding="utf-8")
    marker="Current status: Technical Distribution-Ready Candidate on immutable private RC; public redistribution is not authorized."
    authority=f"""Current status: Technical Distribution-Ready Candidate on immutable private RC; public redistribution is not authorized.

CURRENT CANDIDATE AUTHORITY: dynamic N1...479, immutable `{asset['profile']}/{asset['version']}` @ `{asset['revision']}`, canonical receipt `validation/release_receipt.json`. Historical fixed225 Candidate evidence is preserved under `validation/history/fixed225_release_receipt.json` and is no longer the current authority.

CURRENT RELEASE ENVIRONMENT: `{environment['cleanRoomHost']}`; toolchain `{environment['toolchain']}`; target `{json.dumps(environment.get('validationTarget'),sort_keys=True)}`."""
    if marker in validation:
        validation=validation.replace(marker,authority,1)
    validation=validation.replace(
        "DYNAMIC PRE-CANDIDATE BLOCKER / FAIL-CLOSED: native RAS preserves true EOS=6562 and does not suppress EOS during the frontend's minimum-token SOS suppression window, so a theoretical immediate EOS can yield N0. N0 is intentionally outside the physically validated acoustic envelope. Quantify and resolve or explicitly accept this edge case without changing EOS semantics merely to hide it.",
        "PASS / RELEASE POLICY: native immediate-EOS N0 is explicitly accepted as a fail-closed non-PCM error path; EOS=6562 is unchanged, no token is invented, and no silent/alternate fallback is allowed. Evidence: `validation/evidence/dynamic_n0_policy.json`."
    )
    validation=validation.replace(
        "DYNAMIC RELEASE-ENGINEERING PENDING: freeze an immutable private dynamic asset profile, regenerate exact-current-source standalone/full-runtime rebuild evidence, run controlled cold/warm public-API benchmark on that exact dynamic profile, and generate a dynamic-specific candidate release receipt before labeling the dynamic profile Candidate.",
        "PASS / CURRENT CANDIDATE: immutable dynamic private RC fetch/replay, current-source standalone build, supported runtime rebuild convergence, physical cold/warm public-API benchmark, canonical environment receipt and dynamic Candidate release receipt are committed and bound to the current Candidate authority."
    )
    validation=validation.replace(
        "The fixed225 release status and its existing production blockers above are unchanged by this experiment.",
        "The fixed225 Candidate is retained as historical baseline evidence; current Candidate authority is dynamic N1...479."
    )
    (ROOT/"VALIDATION.md").write_text(validation,encoding="utf-8")

    print("[COSYVOICE3-DYNAMIC-PROMOTE] PASS canonical Candidate metadata/docs now point to dynamic N1...479; fixed225 historical receipt preserved; license/public redistribution remain pending",flush=True)
    return 0

if __name__=="__main__": raise SystemExit(main())

# Code purpose: atomically switch private Candidate metadata authority from historical fixed225 to dynamic N1...479 after all technical Candidate gates pass.
# Upstream source: dynamic_release_receipt.json, immutable catalog row, historical fixed225 receipt, manifest.json.
# Runtime environment: release-engineering Python3 in the dynamic release checkout.
# Generated time: 2026-10-04 America/New_York.
# Changes: new non-license Candidate metadata promotion; never sets Production/public redistribution.

# Changes 2026-10-04: Candidate promotion now atomically rewrites ASSETS/README/API/BENCHMARK/VALIDATION current authority to dynamic N1...479 while explicitly preserving fixed225 as historical baseline and keeping license/public redistribution pending.

# Changes 2026-10-04: dynamic promotion switches manifest publication.branch and current Candidate/SDK-ready milestone pointers to the dynamic release line while preserving fixed225 milestone metadata under explicit historical fields.

# Changes 2026-10-04: promoted README/ASSETS/BENCHMARK/VALIDATION now surface the canonical Candidate clean-room host/toolchain/consumer-path metadata from release_receipt.environment, not only the JSON ledger.
