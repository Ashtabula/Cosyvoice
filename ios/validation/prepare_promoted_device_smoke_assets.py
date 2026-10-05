#!/usr/bin/env python3
# prepare_promoted_device_smoke_assets.py
# Requirement: stage a complete runtime byte-for-byte into DeviceSmoke without overwriting any runtime asset from local conversion candidates; supports promoted replay and unpromoted dynamic-candidate physical smoke with explicit host/source binding.
from __future__ import annotations
import argparse,json,re,shutil,subprocess,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]; OUTPUT=ROOT/"validation/DeviceSmoke/GeneratedAssets"; VALIDATOR=ROOT/"assets/validate_assets.py"
def run(command):
    values=[str(v) for v in command]; print("[COSYVOICE3-PROMOTED-DEVICE-ASSETS] RUN "+" ".join(values),flush=True); subprocess.run(values,check=True)
def main():
    p=argparse.ArgumentParser(); p.add_argument("--asset-root",type=Path,required=True); p.add_argument("--host-receipt",type=Path); p.add_argument("--reference-wav",type=Path,required=True); p.add_argument("--reference-transcript",type=Path,required=True); p.add_argument("--candidate-benchmark",action="store_true"); p.add_argument("--flow-steps-head-to-head",action="store_true"); p.add_argument("--dynamic-public-api-smoke",action="store_true"); a=p.parse_args()
    asset=a.asset_root.resolve(); wav=a.reference_wav.resolve(); transcript=a.reference_transcript.resolve(); host_path=a.host_receipt.resolve() if a.host_receipt is not None else None; run([sys.executable,VALIDATOR,"--root",asset,"--require-reference"])
    if not wav.is_file(): raise RuntimeError(f"reference WAV missing: {wav}")
    if not transcript.is_file() or not transcript.read_text(encoding="utf-8").strip(): raise RuntimeError(f"reference transcript missing/empty: {transcript}")
    if sum(bool(v) for v in (a.candidate_benchmark,a.flow_steps_head_to_head,a.dynamic_public_api_smoke))>1: raise RuntimeError("Candidate benchmark, Flow head-to-head and dynamic public-API smoke modes are mutually exclusive")
    validation_binding=None
    if a.dynamic_public_api_smoke:
        if a.host_receipt is None: raise RuntimeError("--host-receipt is required for dynamic public-API smoke")
        host=json.loads(host_path.read_text(encoding="utf-8"))
        if host.get("schemaVersion")!=2 or host.get("status")!="PASS_HOST_PARITY": raise RuntimeError("host receipt is not schema-2 PASS_HOST_PARITY")
        import hashlib
        host_sha=hashlib.sha256(host_path.read_bytes()).hexdigest()
        source_commit=subprocess.check_output(["git","-C",str(ROOT.parent),"rev-parse","HEAD"],text=True).strip()
        validation_binding={"schemaVersion":1,"benchmark":"dynamic-public-api-default-and-reference-v1","hostReceiptSha256":host_sha,"sourceCommit":source_commit,"bindingSource":"exact candidate runtime + host parity receipt + local Git HEAD"}
    elif a.candidate_benchmark or a.flow_steps_head_to_head:
        release=json.loads((asset/"asset-manifest.json").read_text()); promotion=json.loads((asset/"reference_promotion_receipt.json").read_text()); host_sha=str(release.get("hostReceiptSha256") or "")
        if release.get("hostReceiptStatus")!="PASS_HOST_PARITY" or not re.fullmatch(r"[0-9a-f]{64}",host_sha): raise RuntimeError("immutable asset manifest has no valid PASS host-receipt binding")
        if promotion.get("hostReceipt",{}).get("sha256")!=host_sha or promotion.get("status")!="PASS_CUSTOM_REFERENCE_DEVICE_PROMOTION": raise RuntimeError("immutable promotion receipt host binding mismatch")
        source_commit=subprocess.check_output(["git","-C",str(ROOT.parent),"rev-parse","HEAD"],text=True).strip()
        validation_binding={"schemaVersion":1,"benchmark":"public-api-candidate-v1" if a.candidate_benchmark else "flow-steps-head-to-head-v1","hostReceiptSha256":host_sha,"sourceCommit":source_commit,"bindingSource":"immutable asset-manifest.json + reference_promotion_receipt.json + local Git HEAD"}
    else:
        if a.host_receipt is None: raise RuntimeError("--host-receipt is required outside Candidate benchmark mode")
        host_path=a.host_receipt.resolve(); host=json.loads(host_path.read_text(encoding="utf-8"))
        if host.get("schemaVersion")!=2 or host.get("status")!="PASS_HOST_PARITY": raise RuntimeError("host receipt is not schema-2 PASS_HOST_PARITY")
    reuse=ROOT/".work/device-smoke-reused-input"; reuse.mkdir(parents=True,exist_ok=True)
    if OUTPUT in wav.parents: safe=reuse/"reference.wav"; shutil.copy2(wav,safe); wav=safe
    if OUTPUT in transcript.parents: safe=reuse/"reference.txt"; shutil.copy2(transcript,safe); transcript=safe
    if host_path is not None and OUTPUT in host_path.parents: safe=reuse/"reference_host_parity_receipt.json"; shutil.copy2(host_path,safe); host_path=safe
    if OUTPUT.exists(): shutil.rmtree(OUTPUT)
    OUTPUT.mkdir(parents=True,exist_ok=True); (OUTPUT/".gitkeep").write_text("",encoding="utf-8"); shutil.copytree(asset,OUTPUT/"Runtime"); shutil.copy2(wav,OUTPUT/"reference.wav"); shutil.copy2(transcript,OUTPUT/"reference.txt")
    if validation_binding is not None:
        if a.dynamic_public_api_smoke: marker="dynamic-public-api-smoke-mode.json"
        elif a.candidate_benchmark: marker="candidate-benchmark-mode.json"
        else: marker="flow-step-head-to-head-mode.json"
        (OUTPUT/marker).write_text(json.dumps(validation_binding,indent=2,sort_keys=True)+"\n",encoding="utf-8")
    else: shutil.copy2(host_path,OUTPUT/"reference_host_parity_receipt.json")
    run([sys.executable,VALIDATOR,"--root",OUTPUT/"Runtime","--require-reference"])
    print(f"[COSYVOICE3-PROMOTED-DEVICE-ASSETS] PASS runtime={asset} runtimeBytesPreserved=true localReferenceCandidatesApplied=false candidateBenchmark={a.candidate_benchmark} flowStepsHeadToHead={a.flow_steps_head_to_head} dynamicPublicAPISmoke={a.dynamic_public_api_smoke}",flush=True)
if __name__=="__main__": main()
# Code purpose: stage an immutable fetched/promoted runtime for physical public-API replay or Candidate benchmarking without substituting local model assets.
# Runtime: macOS Python3 standard library.
# Generated: 2026-10-02 America/New_York.
# Changes 2026-10-02: Candidate benchmark mode derives the original PASS_HOST_PARITY SHA from immutable asset-manifest + promotion evidence, so a clean benchmark no longer depends on the historical local host receipt; normal promotion smoke still requires the full host receipt.

# Changes 2026-10-02: Candidate marker now binds the exact local Git HEAD into the app bundle so device PASS/FAIL receipts can prove which SDK binary source was staged.

# Changes 2026-10-02: add mutually exclusive --flow-steps-head-to-head staging that binds the immutable promoted runtime and exact source HEAD into a dedicated validation marker without changing RC assets.

# Changes 2026-10-04: dynamic public-API smoke may exact-stage an unpromoted dynamic candidate root when its active reference enrollment is already PASS_DEVICE_PARITY; marker binds host receipt SHA and exact SDK source HEAD without changing runtime bytes.

# Changes 2026-10-04: snapshot any reference WAV/transcript/host receipt that resides under DeviceSmoke/GeneratedAssets into ios/.work before replacing GeneratedAssets, preventing staging from deleting its own inputs.
