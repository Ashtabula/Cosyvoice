#@title finalize_candidate_metadata.py
# Requirement: after Candidate evidence has passed, atomically rewrite release metadata/docs to the ZipVoice-equivalent Technical Distribution-Ready Candidate state without authorizing public redistribution.
from __future__ import annotations
import argparse,json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def load(path): return json.loads(path.read_text())
def write_json(path,value): path.parent.mkdir(parents=True,exist_ok=True); path.write_text(json.dumps(value,indent=2,sort_keys=True)+"\n")
def transition(text,old,new,label):
    if old in text: return text.replace(old,new)
    if new in text: return text
    raise RuntimeError(label+" transition text missing")
def main():
    p=argparse.ArgumentParser(); p.add_argument("--receipt",type=Path,default=ROOT/"validation/release_receipt.json"); a=p.parse_args(); receipt=load(a.receipt)
    if receipt.get("releaseStatus")!="candidate" or receipt.get("technicalDistributionReady") is not True or receipt.get("publicRedistributionApproved") is not False: raise RuntimeError("Candidate release receipt state mismatch")
    if any(v.get("status")!="PASS" for v in receipt.get("checks",{}).values()): raise RuntimeError("Candidate release receipt contains non-PASS checks")
    benchmark=load(ROOT/"validation/evidence/candidate_benchmark.json"); rebuild=load(ROOT/"validation/evidence/full_runtime_rebuild.json"); manifest_path=ROOT/"manifest.json"; manifest=load(manifest_path)
    if manifest.get("publicRedistributionApproved") is not False: raise RuntimeError("refusing Candidate transition from public-redistribution-approved state")
    manifest["releaseStatus"]="candidate"; manifest["shippingReady"]=False; manifest["sdkIntegrationReady"]=True; manifest["technicalDistributionReady"]=True; manifest["candidateBlockers"]=[]; manifest["releaseReadiness"]="Technical Distribution-Ready Candidate for ios-fixed225-reference. Public API, immutable private-RC fetch/replay, supported full-runtime rebuild and controlled cold/warm physical-device benchmark are validated. Production/public redistribution remains blocked by clean-room consumer integration, release-tree reproducibility and license/redistribution review."; manifest["candidateReleaseReceipt"]="validation/release_receipt.json"; manifest["candidateMilestone"]={"status":"PASS","date":"2026-10-02","receipt":"validation/ios_fixed225_distribution_ready_2026-10-02.json","milestone":"MILESTONES/IOS_FIXED225_DISTRIBUTION_READY_2026-10-02.md"}
    write_json(manifest_path,manifest)
    catalog_path=ROOT/"assets/releases.json"; catalog=load(catalog_path); default=catalog["default"]; rows=[x for x in catalog["releases"] if x.get("profile")==default["profile"] and x.get("version")==default["version"]]
    if len(rows)!=1: raise RuntimeError("release catalog default is not unique")
    row=rows[0]; row["sdkIntegrationReady"]=True; row["candidateTechnicalDistributionReady"]=True; row["publicRedistributionApproved"]=False; row["sdkReleaseStatus"]="CANDIDATE_PRIVATE_ASSETS"; write_json(catalog_path,catalog)
    checklist_path=ROOT/"RELEASE_CHECKLIST.md"; text=checklist_path.read_text(); text=transition(text,"Current status: SDK integration-ready on private RC; release level remains Development.","Current status: Technical Distribution-Ready Candidate on immutable private RC; public redistribution is not authorized.","checklist current status")
    replacements={
        "CANDIDATE BLOCKER: current-source standalone build and supported full-runtime rebuild evidence must be regenerated after the public Flow-default/API change.":"PASS: current-source standalone build and supported full-runtime rebuild evidence are regenerated and bound to this promotion commit.",
        "CANDIDATE BLOCKER: controlled cold/warm public-API benchmark evidence must be regenerated with production default flowSteps=6.":"PASS: controlled physical-device cold/warm benchmark through CosyVoice3Engine public API validates production default flowSteps=6.",
        "CANDIDATE BLOCKER: `validation/release_receipt.json` is bound to an older source commit and must be regenerated.":"PASS: Candidate `validation/release_receipt.json` ties current source, rebuild, immutable assets, parity, device PCM and 6-step benchmark evidence together.",
        "Do not label Candidate or set `technicalDistributionReady=true` until all current-source Candidate blockers have committed evidence. After Candidate, do not label Production or authorize public runtime assets until the remaining Production blockers pass.":"Candidate engineering gates are complete. Do not label Production or authorize public runtime assets until the remaining Production blockers pass."
    }
    for old,new in replacements.items(): text=transition(text,old,new,"checklist")
    checklist_path.write_text(text)
    m=benchmark["measurement"]; benchmark_text=f"""# CosyVoice3 iOS benchmark status

Current Candidate benchmark: **PASS — physical-device public-API cold/warm evidence recorded.**

The benchmark uses the exact immutable `ios-fixed225-reference/0.1.0-rc1` private RC through `CosyVoice3Engine.synthesize()`. The first synthesis starts from a fresh process and fresh engine and does not call `validateReference()` beforehand; the repeat synthesis uses the same engine instance and identical text/reference/instruction workload. Performance numbers are measurements, not release thresholds.

Device: `{benchmark['device']['modelIdentifier']}`, iOS `{benchmark['device']['systemVersion']}`.
Engine init: `{m['engineInitMilliseconds']:.3f} ms`.
Flow steps: `{m['flowSteps']}` (production default).
First synthesis: `{m['firstSynthesisMilliseconds']:.3f} ms`, audio `{m['firstAudioSeconds']:.6f} s`, RTF `{m['firstRTF']:.6f}`.
Warm repeat: `{m['repeatSynthesisMilliseconds']:.3f} ms`, audio `{m['repeatAudioSeconds']:.6f} s`, RTF `{m['repeatRTF']:.6f}`.
Output: `{m['firstSamples']}` / `{m['repeatSamples']}` samples, mono Float32 PCM at 24 kHz, finite.
Asset payload tree: `{benchmark['asset']['payloadTreeSha256']}`.
Asset revision: `{benchmark['asset']['revision']}`.
Evidence: `validation/evidence/candidate_benchmark.json`.

Earlier StatefulLLMBench/full-pipeline measurements remain development provenance and are not substituted for this SDK Candidate benchmark. Core ML execution is not relabeled as proven ANE residency without independent placement evidence.
"""
    (ROOT/"BENCHMARK.md").write_text(benchmark_text)
    readme_path=ROOT/"README.md"; readme=readme_path.read_text(); readme=transition(readme,"Status: **SDK integration-ready on private RC; release level remains Development.** Publication target: `Ashtabula/Cosyvoice/ios/`.","Status: **Technical Distribution-Ready Candidate on immutable private RC; public redistribution is not authorized.** Publication target: `Ashtabula/Cosyvoice/ios/`.","README status")
    readme=transition(readme,"The exact hosted revision passed authenticated ordinary-developer fetch, validation, installation and physical-iPhone public-API replay. This supports `sdkIntegrationReady=true`; the current SDK source does not yet support `technicalDistributionReady=true` because the public Flow-default/API change postdates the last source-bound Candidate evidence.","The exact hosted revision passed authenticated ordinary-developer fetch, validation, installation and physical-iPhone public-API replay. Current-source Candidate evidence now validates the supported full-runtime rebuild and controlled cold/warm public-API benchmark at flowSteps=6, so `sdkIntegrationReady=true` and `technicalDistributionReady=true`; public redistribution remains false.","README readiness")
    old="The previously committed Candidate evidence remains useful historical evidence for the immutable RC assets, but it predates the production Flow-default/API change and therefore does not certify the current SDK source commit. Re-promotion requires current-source standalone build and supported full-runtime rebuild evidence, a controlled cold/warm physical-device public-API benchmark at the production 6-step Flow default, and a regenerated `validation/release_receipt.json`. Production still separately requires clean-room consumer integration, release-tree reproducibility and redistribution/license clearance. Human listening acceptance for the 6-step Flow setting is PASS."
    new="The same **Technical Distribution-Ready Candidate** engineering state used by ZipVoice iOS is now represented by current-source committed evidence: supported full-runtime rebuild, controlled cold/warm physical-device public-API benchmark at the production 6-step Flow default, and `validation/release_receipt.json`. Production still requires clean-room consumer integration, release-tree reproducibility and redistribution/license clearance. Human listening acceptance for the 6-step Flow setting remains PASS."
    readme_path.write_text(transition(readme,old,new,"README Candidate paragraph"))
    sdk_path=ROOT/"SDK_RELEASE.md"; sdk_text=sdk_path.read_text(); old_sdk="The current SDK source is intentionally below the ZipVoice iOS **Technical Distribution-Ready Candidate** milestone because the public Flow default/API changed after the last source-bound Candidate evidence. `technicalDistributionReady=false` until the current-source build/rebuild evidence, the controlled cold/warm benchmark at flowSteps=6, and the Candidate release receipt are regenerated. Public redistribution remains unauthorized until the later Production gates are closed."
    new_sdk="This branch now satisfies the ZipVoice iOS **Technical Distribution-Ready Candidate** engineering gates on the current source: build/rebuild evidence, controlled cold/warm physical-device public-API benchmark at flowSteps=6, and Candidate release receipt are committed. `technicalDistributionReady=true`; public redistribution remains unauthorized until the Production clean-room/reproducibility/license gates are closed."
    sdk_path.write_text(transition(sdk_text,old_sdk,new_sdk,"SDK_RELEASE Candidate paragraph"))
    api_path=ROOT/"API.md"; api_text=api_path.read_text(); old_api="The immutable `ios-fixed225-reference/0.1.0-rc1` private asset profile passed ordinary-developer fetch plus physical public-API replay. Re-promotion to Candidate now requires current-source supported full-runtime rebuild evidence, a controlled cold/warm public-API benchmark at the production 6-step Flow default, and a regenerated `validation/release_receipt.json`."
    new_api="The immutable `ios-fixed225-reference/0.1.0-rc1` private asset profile passed ordinary-developer fetch plus physical public-API replay. Current-source Candidate evidence now additionally includes the supported full-runtime rebuild, controlled cold/warm public-API benchmark at flowSteps=6, and `validation/release_receipt.json`; Production/public release remains separately gated."
    api_text=transition(api_text,"Status: SDK integration-ready on immutable private RC; current-source Candidate evidence must be regenerated after the public 6-step Flow-default/API change.","Status: Technical Distribution-Ready Candidate on immutable private RC; public redistribution is not authorized.","API status")
    api_path.write_text(transition(api_text,old_api,new_api,"API Candidate paragraph"))
    assets_path=ROOT/"ASSETS.md"; assets_text=assets_path.read_text(); old_assets="Status: immutable private-RC asset distribution remains validated and device-replayed; current SDK Candidate status is pending revalidation after the public 6-step Flow-default/API change."
    new_assets="Status: Technical Distribution-Ready Candidate on immutable private RC; ordinary fetch/replay plus current-source supported full-runtime rebuild and controlled 6-step physical-device benchmark evidence are committed; public redistribution is not authorized."
    assets_path.write_text(transition(assets_text,old_assets,new_assets,"ASSETS Candidate status"))
    milestone={"schemaVersion":1,"milestone":"ios-fixed225-distribution-ready-technical-2026-10-02","status":"PASS","releaseStatus":"candidate","technicalDistributionReady":True,"publicRedistributionApproved":False,"validatedSourceCommit":receipt["validatedSourceCommit"],"releaseReceipt":"validation/release_receipt.json","assets":receipt["asset"],"device":receipt["device"],"supportedFullRuntimeRebuild":{"status":"PASS","runtimeTreeSha256":rebuild["runtimeTreeSha256"],"runtimeBytes":rebuild["runtimeBytes"],"canonicalByteIdentityClaim":False},"controlledBenchmark":{"status":"PASS",**m},"remainingProductionBlockers":["clean-room consumer integration","release-tree reproducibility","asset redistribution license review"],"publisher":{"name":"actacomes","email":"developer@actacomes.com"}}
    write_json(ROOT/"validation/ios_fixed225_distribution_ready_2026-10-02.json",milestone)
    md=f"""# iOS fixed225 Technical Distribution-Ready milestone — 2026-10-02

Status: **PASS — Technical Distribution-Ready Candidate / public redistribution not authorized**

This milestone follows the ZipVoice iOS release flow. The public SDK boundary, immutable private-RC ordinary-developer fetch/replay, pinned supported full-runtime rebuild, physical public-API PCM and controlled cold/warm benchmark are all represented by committed machine-readable evidence.

Validated source commit: `{receipt['validatedSourceCommit']}`.
Asset profile/version: `{receipt['asset']['profile']}/{receipt['asset']['version']}`.
Immutable HF revision: `{receipt['asset']['revision']}`.
Payload tree: `{receipt['asset']['payloadTreeSha256']}`.
Tested runtime tree: `{receipt['asset']['testedRuntimeTreeSha256']}`.
Supported rebuild tree: `{rebuild['runtimeTreeSha256']}`; byte-identical canonical rebuild is not claimed.
Physical target: `{benchmark['device']['modelIdentifier']}`, iOS `{benchmark['device']['systemVersion']}`.
First synthesis: `{m['firstSynthesisMilliseconds']:.3f} ms`, RTF `{m['firstRTF']:.6f}`.
Warm repeat: `{m['repeatSynthesisMilliseconds']:.3f} ms`, RTF `{m['repeatRTF']:.6f}`.

State:

```text
releaseStatus = candidate
sdkIntegrationReady = true
technicalDistributionReady = true
publicRedistributionApproved = false
```

Production/public release remains blocked by clean-room consumer integration, release-tree reproducibility and asset redistribution/license review. Human listening acceptance remains PASS from the unchanged promoted runtime evidence.
"""
    path=ROOT/"MILESTONES/IOS_FIXED225_DISTRIBUTION_READY_2026-10-02.md"; path.parent.mkdir(parents=True,exist_ok=True); path.write_text(md)
    print("[COSYVOICE3-CANDIDATE-METADATA] PASS",flush=True)
if __name__=="__main__": main()
# Code purpose: perform the evidence-gated Development -> Candidate metadata transition and freeze a ZipVoice-style technical Distribution-Ready milestone.
# Upstream: validation/release_receipt.json, supported rebuild evidence, controlled Candidate benchmark, immutable asset catalog.
# Runtime: Python 3 standard library inside the release checkout.
# Generated: 2026-10-02 America/New_York.
# Changes: new file; updates manifest/catalog/checklist/benchmark/README/SDK/API/assets documentation and writes machine/human-readable Candidate milestone evidence while preserving publicRedistributionApproved=false.\n# Changes 2026-10-02: removed accidental backslash escapes before Markdown backticks in exact transition strings and records the Candidate milestone paths in manifest.json.\n# Changes 2026-10-02: make Development->Candidate text transitions strictly idempotent for full revalidation; already-canonical Candidate text is accepted unchanged, while any third/unrecognized state still fails closed.

# Changes 2026-10-03: revalidation transitions now match the post-6-step Development state and Candidate benchmark documentation records the production Flow step count.

# Changes 2026-10-03: Candidate finalization now consumes the exact post-6-step README/API Development wording, preventing a successful revalidation from leaving stale Development claims behind.
