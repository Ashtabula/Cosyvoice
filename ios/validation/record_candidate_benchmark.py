#@title record_candidate_benchmark.py
# Requirement: sanitize and bind one physical-device cold/warm public-API benchmark receipt to the exact immutable private-RC asset identity and current SDK source commit.
from __future__ import annotations
import argparse,hashlib,json,subprocess,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]

def sha(path):
    h=hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda:f.read(8*1024*1024),b""): h.update(block)
    return h.hexdigest()

def load(path):
    if not path.is_file(): raise RuntimeError(f"missing JSON: {path}")
    value=json.loads(path.read_text())
    if not isinstance(value,dict): raise RuntimeError(f"JSON object required: {path}")
    return value

def main():
    p=argparse.ArgumentParser(); p.add_argument("--raw-receipt",type=Path,required=True); p.add_argument("--asset-root",type=Path,required=True); p.add_argument("--reference-wav",type=Path,required=True); p.add_argument("--reference-transcript",type=Path,required=True); p.add_argument("--output",type=Path,required=True); a=p.parse_args()
    raw=load(a.raw_receipt.resolve()); asset=load(a.asset_root.resolve()/"asset-manifest.json"); catalog=load(ROOT/"assets/releases.json"); promotion=load(ROOT/"validation/reference-device/promotion-receipt.json")
    matches=[r for r in catalog.get("releases",[]) if r.get("profile")==asset.get("profile") and r.get("version")==asset.get("assetVersion")]
    if len(matches)!=1: raise RuntimeError("release catalog has no unique entry for the fetched asset manifest")
    release=matches[0]
    if raw.get("schemaVersion")!=1 or raw.get("status")!="PASS_CANDIDATE_BENCHMARK" or raw.get("benchmark")!="public-api-candidate-v1": raise RuntimeError("raw Candidate benchmark identity/status mismatch")
    if raw.get("referenceValidationPrewarm") is not False: raise RuntimeError("Candidate benchmark unexpectedly prewarmed reference validation")
    if raw.get("sampleRate")!=24000 or raw.get("channels")!=1 or raw.get("finite") is not True: raise RuntimeError("Candidate benchmark PCM contract mismatch")
    if raw.get("flowSteps")!=6: raise RuntimeError(f"Candidate benchmark must exercise production default flowSteps=6, got {raw.get('flowSteps')!r}")
    for stage_name in ("firstStages","repeatStages"):
        stage=raw.get(stage_name)
        if not isinstance(stage,dict) or stage.get("flowSteps")!=6: raise RuntimeError(f"Candidate benchmark {stage_name} does not prove flowSteps=6")
    dynamic_profile=str(asset.get("runtimeProfile") or "").startswith("ios18-dynamic-")
    if dynamic_profile:
        if raw.get("profile")!=asset.get("runtimeManifestProfile"): raise RuntimeError("dynamic Candidate benchmark runtime profile mismatch")
        bounds=asset.get("speechTokenBounds")
        if bounds!=[1,479] or raw.get("speechTokenBounds")!=bounds: raise RuntimeError("dynamic Candidate benchmark N bounds mismatch")
        placement=raw.get("requestedComputePlacement") or {}
        if placement.get("llmPrefill")!="CPU_ONLY" or placement.get("llmDecode")!="CPU_ONLY" or placement.get("dynamicAcoustic")!="CPU_AND_NE" or placement.get("referenceEncoders")!="CPU_ONLY": raise RuntimeError("dynamic Candidate benchmark requested placement mismatch")
        if (raw.get("dynamicAcousticExecutionHints") or {}).get("reshapeFrequency")!="INFREQUENT": raise RuntimeError("dynamic Candidate benchmark reshapeFrequency mismatch")
        for key in ("firstSamples","repeatSamples"):
            samples=int(raw.get(key,0))
            if samples<=0 or samples%960!=0: raise RuntimeError(f"dynamic Candidate benchmark invalid {key}")
            n=samples//960
            if not (bounds[0]<=n<=bounds[1]): raise RuntimeError(f"dynamic Candidate benchmark {key} implies N={n} outside bounds")
    else:
        if int(raw.get("firstSamples",0))!=216000 or int(raw.get("repeatSamples",0))!=216000: raise RuntimeError("Candidate benchmark is not the fixed225 9-second output contract")
    for key in ("engineInitMilliseconds","firstSynthesisMilliseconds","repeatSynthesisMilliseconds","firstRTF","repeatRTF"):
        if float(raw.get(key,0))<=0: raise RuntimeError(f"Candidate benchmark invalid {key}")
    if not raw.get("deviceModelIdentifier") or not raw.get("systemVersion"): raise RuntimeError("Candidate benchmark device identity incomplete")
    if raw.get("hostReceiptSha256")!=promotion.get("hostReceipt",{}).get("sha256"): raise RuntimeError("Candidate benchmark host-parity binding mismatch")
    if asset.get("profile")!=release.get("profile") or asset.get("assetVersion")!=release.get("version") or asset.get("payloadTreeSha256")!=release.get("payloadTreeSha256") or asset.get("testedRuntimeTreeSha256")!=release.get("testedRuntimeTreeSha256"): raise RuntimeError("Candidate benchmark asset identity differs from committed release catalog")
    wav=a.reference_wav.resolve(); transcript_path=a.reference_transcript.resolve()
    if not wav.is_file(): raise RuntimeError("Candidate benchmark reference WAV missing")
    transcript=transcript_path.read_text(encoding="utf-8").strip()
    if not transcript: raise RuntimeError("Candidate benchmark reference transcript missing/empty")
    if len(transcript)!=int(raw.get("referenceTranscriptCharacters",0)): raise RuntimeError("Candidate benchmark transcript length differs from device receipt")
    head=subprocess.check_output(["git","-C",str(ROOT.parent),"rev-parse","HEAD"],text=True).strip()
    if raw.get("sourceCommit")!=head: raise RuntimeError(f"raw Candidate benchmark sourceCommit {raw.get('sourceCommit')!r} != current HEAD {head}")
    receipt={"schemaVersion":1,"status":"PASS","benchmark":"public-api-candidate-v1","sourceCommit":head,"runtimeProfile":asset.get("runtimeProfile"),"runtimeManifestProfile":asset.get("runtimeManifestProfile"),"speechTokenBounds":asset.get("speechTokenBounds"),"asset":{"profile":release["profile"],"version":release["version"],"repoId":release["repoId"],"revision":release["revision"],"payloadTreeSha256":release["payloadTreeSha256"],"testedRuntimeTreeSha256":release["testedRuntimeTreeSha256"]},"device":{"model":raw.get("device"),"modelIdentifier":raw["deviceModelIdentifier"],"systemName":raw.get("systemName"),"systemVersion":raw["systemVersion"]},"workload":{"text":"This is a CosyVoice3 public API reference voice validation.","instructionPrefix":"You are a helpful assistant.<|endofprompt|>","referenceWavSha256":sha(wav),"referenceWavBytes":wav.stat().st_size,"referenceTranscriptSha256":hashlib.sha256(transcript.encode("utf-8")).hexdigest(),"referenceTranscriptCharacters":len(transcript)},"measurement":{"flowSteps":6,"coldDefinition":raw.get("coldDefinition"),"warmDefinition":raw.get("warmDefinition"),"referenceValidationPrewarm":False,"engineInitMilliseconds":raw["engineInitMilliseconds"],"firstSynthesisMilliseconds":raw["firstSynthesisMilliseconds"],"repeatSynthesisMilliseconds":raw["repeatSynthesisMilliseconds"],"firstAudioSeconds":raw["firstAudioSeconds"],"repeatAudioSeconds":raw["repeatAudioSeconds"],"firstRTF":raw["firstRTF"],"repeatRTF":raw["repeatRTF"],"firstSamples":raw["firstSamples"],"repeatSamples":raw["repeatSamples"],"sameSampleCount":raw.get("sameSampleCount"),"sampleRate":24000,"channels":1,"finite":True,"firstStages":raw.get("firstStages"),"repeatStages":raw.get("repeatStages")},"requestedComputePlacement":raw.get("requestedComputePlacement"),"dynamicAcousticExecutionHints":raw.get("dynamicAcousticExecutionHints"),"hostReceiptSha256":raw["hostReceiptSha256"],"recordedAtUnix":int(time.time()),"performanceThresholdApplied":False}
    a.output.parent.mkdir(parents=True,exist_ok=True); a.output.write_text(json.dumps(receipt,indent=2,sort_keys=True)+"\n"); print("[COSYVOICE3-CANDIDATE-BENCHMARK] PASS "+json.dumps(receipt,sort_keys=True),flush=True)

if __name__=="__main__": main()

# Code purpose: convert the DeviceSmoke raw benchmark into committed Candidate evidence bound to exact SDK/HF/runtime identities.
# Upstream source: DeviceSmoke public CosyVoice3Engine benchmark, assets/releases.json, fetched asset-manifest.json, reference promotion receipt.
# Runtime environment: macOS Python 3 standard library after physical iPhone benchmark retrieval.
# Generated: 2026-10-02 America/New_York.
# Changes: fixes malformed literal newline escapes; enforces no reference prewarm, fixed225 PCM, positive cold/warm measurements, device identity, host-parity binding, immutable asset identity, and workload hashes; no speed threshold is imposed.

# Changes 2026-10-02: preserve optional public-SDK stage timing dictionaries from the device receipt so cold/warm optimization decisions can be based on measured preparation/LLM/acoustic components.

# Changes 2026-10-02: raw device benchmark must prove it was produced by the exact current Git HEAD before host-side Candidate evidence can be recorded; stale app binaries/receipts now fail closed.

# Changes 2026-10-03: Candidate recording requires production flowSteps=6 in the raw receipt and both stage reports, and preserves it in committed measurement evidence.

# Changes 2026-10-04: Candidate benchmark recorder now binds the exact fetched asset profile/version rather than catalog default. Dynamic N1 profiles validate variable 960*N outputs, N1...479 bounds, requested mixed placement and reshapeFrequency=INFREQUENT while fixed225 retains its exact 216000-sample contract.
