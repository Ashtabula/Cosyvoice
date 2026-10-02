#@title record_candidate_benchmark.py
# Requirement: sanitize and bind one physical-device cold/warm public-API benchmark receipt to the exact immutable private-RC asset identity and current SDK source commit.
from __future__ import annotations
import argparse,json,subprocess,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def load(path):
    if not path.is_file(): raise RuntimeError(f"missing JSON: {path}")
    value=json.loads(path.read_text())
    if not isinstance(value,dict): raise RuntimeError(f"JSON object required: {path}")
    return value
def main():
    p=argparse.ArgumentParser(); p.add_argument("--raw-receipt",type=Path,required=True); p.add_argument("--asset-root",type=Path,required=True); p.add_argument("--output",type=Path,required=True); a=p.parse_args()
    raw=load(a.raw_receipt.resolve()); asset=load(a.asset_root.resolve()/"asset-manifest.json"); catalog=load(ROOT/"assets/releases.json"); promotion=load(ROOT/"validation/reference-device/promotion-receipt.json")
    default=catalog.get("default") or {}; matches=[r for r in catalog.get("releases",[]) if r.get("profile")==default.get("profile") and r.get("version")==default.get("version")]
    if len(matches)!=1: raise RuntimeError("release catalog default is not unique")
    release=matches[0]
    if raw.get("schemaVersion")!=1 or raw.get("status")!="PASS_CANDIDATE_BENCHMARK" or raw.get("benchmark")!="public-api-candidate-v1": raise RuntimeError("raw Candidate benchmark identity/status mismatch")
    if raw.get("referenceValidationPrewarm") is not False: raise RuntimeError("Candidate benchmark unexpectedly prewarmed reference validation")
    if raw.get("sampleRate")!=24000 or raw.get("channels")!=1 or raw.get("finite") is not True: raise RuntimeError("Candidate benchmark PCM contract mismatch")
    if int(raw.get("firstSamples",0))!=216000 or int(raw.get("repeatSamples",0))!=216000: raise RuntimeError("Candidate benchmark is not the fixed225 9-second output contract")
    for key in ("engineInitMilliseconds","firstSynthesisMilliseconds","repeatSynthesisMilliseconds","firstRTF","repeatRTF"):
        if float(raw.get(key,0))<=0: raise RuntimeError(f"Candidate benchmark invalid {key}")
    if not raw.get("deviceModelIdentifier") or not raw.get("systemVersion"): raise RuntimeError("Candidate benchmark device identity incomplete")
    if raw.get("hostReceiptSha256")!=promotion.get("hostReceipt",{}).get("sha256"): raise RuntimeError("Candidate benchmark host-parity binding mismatch")
    if asset.get("profile")!=release.get("profile") or asset.get("assetVersion")!=release.get("version") or asset.get("payloadTreeSha256")!=release.get("payloadTreeSha256") or asset.get("testedRuntimeTreeSha256")!=release.get("testedRuntimeTreeSha256"): raise RuntimeError("Candidate benchmark asset identity differs from committed release catalog")
    head=subprocess.check_output(["git","-C",str(ROOT.parent),"rev-parse","HEAD"],text=True).strip()
    receipt={"schemaVersion":1,"status":"PASS","benchmark":"public-api-candidate-v1","sourceCommit":head,"asset":{"profile":release["profile"],"version":release["version"],"repoId":release["repoId"],"revision":release["revision"],"payloadTreeSha256":release["payloadTreeSha256"],"testedRuntimeTreeSha256":release["testedRuntimeTreeSha256"]},"device":{"model":raw.get("device"),"modelIdentifier":raw["deviceModelIdentifier"],"systemName":raw.get("systemName"),"systemVersion":raw["systemVersion"]},"measurement":{"coldDefinition":raw.get("coldDefinition"),"warmDefinition":raw.get("warmDefinition"),"referenceValidationPrewarm":False,"engineInitMilliseconds":raw["engineInitMilliseconds"],"firstSynthesisMilliseconds":raw["firstSynthesisMilliseconds"],"repeatSynthesisMilliseconds":raw["repeatSynthesisMilliseconds"],"firstAudioSeconds":raw["firstAudioSeconds"],"repeatAudioSeconds":raw["repeatAudioSeconds"],"firstRTF":raw["firstRTF"],"repeatRTF":raw["repeatRTF"],"firstSamples":raw["firstSamples"],"repeatSamples":raw["repeatSamples"],"sameSampleCount":raw.get("sameSampleCount"),"sampleRate":24000,"channels":1,"finite":True},"hostReceiptSha256":raw["hostReceiptSha256"],"recordedAtUnix":int(time.time()),"performanceThresholdApplied":False}
    a.output.parent.mkdir(parents=True,exist_ok=True); a.output.write_text(json.dumps(receipt,indent=2,sort_keys=True)+"\n"); print("[COSYVOICE3-CANDIDATE-BENCHMARK] PASS "+json.dumps(receipt,sort_keys=True),flush=True)
if __name__=="__main__": main()
# Code purpose: convert the DeviceSmoke raw benchmark into committed Candidate evidence bound to exact SDK/HF/runtime identities.
# Upstream: DeviceSmoke public CosyVoice3Engine benchmark, assets/releases.json, fetched asset-manifest.json, reference promotion receipt.
# Runtime: macOS Python 3 standard library after physical iPhone benchmark retrieval.
# Generated: 2026-10-02 America/New_York.
# Changes: new file; enforces no reference prewarm, fixed225 216000-sample PCM, positive cold/warm measurements, device identity, host-parity binding and exact immutable release-catalog asset identity; no numerical speed threshold is imposed.
