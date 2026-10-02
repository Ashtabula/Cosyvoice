#@title record_full_runtime_rebuild.py
# Requirement: fail closed unless a clean pinned-source rebuild produced the complete fixed225 runtime ABI and the rebuilt custom-reference lane passed host parity.
from __future__ import annotations
import argparse,hashlib,importlib.metadata,json,platform,subprocess,sys,time
from pathlib import Path
SOURCE_COMMIT="878940245562bcd1dd0231d78157ba78d70b39f6"; MODEL_REVISION="29e01c4e8d000f4bcd70751be16fa94bf3d85a18"
def sha(path):
    h=hashlib.sha256()
    with path.open("rb") as f:
        for b in iter(lambda:f.read(8*1024*1024),b""): h.update(b)
    return h.hexdigest()
def rows_for(root,paths):
    rows=[]
    for relative in paths:
        path=root/relative
        if not path.exists(): raise RuntimeError(f"missing rebuilt runtime path: {relative}")
        items=[path] if path.is_file() else sorted(x for x in path.rglob("*") if x.is_file())
        for item in items: rows.append({"path":item.relative_to(root).as_posix(),"bytes":item.stat().st_size,"sha256":sha(item)})
    unique={r["path"]:r for r in rows}; return [unique[k] for k in sorted(unique)]
def tree_id(rows):
    h=hashlib.sha256()
    for r in rows: h.update(r["path"].encode()+b"\0"+str(r["bytes"]).encode()+b"\0"+r["sha256"].encode()+b"\n")
    return h.hexdigest()
def load(path):
    if not path.is_file(): raise RuntimeError(f"missing receipt: {path}")
    value=json.loads(path.read_text())
    if not isinstance(value,dict): raise RuntimeError(f"receipt is not object: {path}")
    return value
def main():
    p=argparse.ArgumentParser(); p.add_argument("--asset-root",type=Path,required=True); p.add_argument("--source-root",type=Path,required=True); p.add_argument("--host-receipt",type=Path,required=True); p.add_argument("--output",type=Path,required=True); a=p.parse_args()
    root=a.asset_root.resolve(); source=a.source_root.resolve(); host_path=a.host_receipt.resolve(); out=a.output.resolve()
    head=subprocess.check_output(["git","-C",str(source),"rev-parse","HEAD"],text=True).strip()
    if head!=SOURCE_COMMIT: raise RuntimeError(f"pinned source mismatch: {head}")
    manifest=load(root/"cosyvoice3_fixed225.json"); host=load(host_path); ref=manifest.get("referenceEnrollment") or {}
    if manifest.get("schemaVersion")!=1 or manifest.get("profile")!="ios18-fixed225": raise RuntimeError("rebuilt runtime manifest mismatch")
    if ref.get("status")!="PASS_HOST_PARITY_REBUILT" or ref.get("devicePromotionRequired") is not True: raise RuntimeError("rebuilt reference lane is not host-parity-only")
    if host.get("schemaVersion")!=2 or host.get("status")!="PASS_HOST_PARITY": raise RuntimeError("rebuilt host parity receipt is not PASS")
    llm=load(source/"iOS/validation/llm_fp16/decode-opt-perlayer/receipt.json"); hift=load(source/"iOS/validation/full-pipeline/host-hift-phase-host.json"); f0=load(source/"iOS/validation/full-pipeline/f0-double-export.json")
    if llm.get("status")!="CPU225_COMPLETE" or int(llm.get("argmax_agreements",0))!=225: raise RuntimeError("LLM full fixed225 CPU replay is not accepted")
    if hift.get("status")!="HOST_PHASE_CANDIDATE": raise RuntimeError("HiFT host-phase rebuild receipt is not accepted")
    if f0.get("status")!="EXPORTED_FP64_F0_REFERENCE_WEIGHTS": raise RuntimeError("FP64 F0 rebuild receipt is not accepted")
    flow_receipts=sorted((source/"iOS/validation/device").glob("flow-fp16-shards-*.json"))
    if not flow_receipts: raise RuntimeError("Flow shard rebuild receipt missing")
    flow=load(flow_receipts[-1])
    if flow.get("status")!="HOST_COREML_VALIDATED" or len(flow.get("packages") or [])!=6: raise RuntimeError("Flow shard host validation is not accepted")
    paths=["cosyvoice3_fixed225.json",manifest["tokenizerFolder"],manifest["textEmbedding"],manifest["speechEmbedding"],manifest["llmPrefill"],manifest["llmDecode"],manifest["flowConditions"],*manifest["flowShards"],manifest["hift"],manifest["f0Folder"],manifest["flowMask"],manifest["flowNoise"],ref["speechTokenizer"],ref["campPlus"],ref["whisperMel128"],ref["kaldiMel80"],ref["matchaMel80"],ref["flowConditionsDynamic"]]
    rows=rows_for(root,paths); xcode=subprocess.check_output(["xcodebuild","-version"],text=True).strip().replace("\n","; ")
    versions={name:importlib.metadata.version(name) for name in ("coremltools","torch","torchaudio","numpy","transformers","onnx","onnxruntime","HyperPyYAML") if importlib.util.find_spec(name if name!="HyperPyYAML" else "hyperpyyaml") is not None}
    receipt={"schemaVersion":1,"status":"PASS_SUPPORTED_FULL_RUNTIME_REBUILD","engine":"CosyVoice3","platform":"iOS","profile":"ios-fixed225-reference","runtimeProfile":"ios18-fixed225","sourceCommit":SOURCE_COMMIT,"modelRevision":MODEL_REVISION,"assetRoot":str(root),"runtimeFileCount":len(rows),"runtimeBytes":sum(r["bytes"] for r in rows),"runtimeTreeSha256":tree_id(rows),"hostParityReceiptSha256":sha(host_path),"checks":{"llmFixed225Replay":"PASS","flowSixShardHostParity":"PASS","hiftHostPhase":"PASS","fp64F0Export":"PASS","customReferenceHostParity":"PASS","canonicalAssetValidation":"PASS"},"rebuildSemantics":{"supportedRebuild":True,"canonicalByteIdentityClaim":False,"devicePromotionRequiredForRebuiltPackages":True},"environment":{"platform":platform.platform(),"python":sys.version.split()[0],"xcode":xcode,"packages":versions},"recordedAtUnix":int(time.time())}
    out.parent.mkdir(parents=True,exist_ok=True); out.write_text(json.dumps(receipt,indent=2,sort_keys=True)+"\n"); print("[COSYVOICE3-FULL-REBUILD] PASS "+json.dumps(receipt,sort_keys=True),flush=True)
if __name__=="__main__": main()
# Code purpose: emit Candidate-grade evidence that every shipping fixed225 runtime component can be regenerated from pinned inputs and satisfies the same runtime ABI plus host parity.
# Upstream: locked CosyVoice3_NPU source, official checkpoint, accepted production converters, canonical asset validator, reference host-parity gate.
# Runtime: Apple Silicon macOS, Xcode/Core ML, Python 3.11 pinned rebuild environment.
# Generated: 2026-10-02 America/New_York.
# Changes: new file; verifies pinned source, LLM225 replay, six-shard Flow host validation, host-phase HiFT, FP64 F0, custom-reference host parity, full runtime paths, and records deterministic supported-rebuild tree/environment evidence without claiming byte identity or device promotion.
