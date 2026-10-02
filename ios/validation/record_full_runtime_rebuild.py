#@title record_full_runtime_rebuild.py
# Requirement: fail closed unless a clean pinned-source rebuild produced the complete fixed225 runtime ABI, used the exact derived acoustic-only config, and the rebuilt custom-reference lane passed host parity.
from __future__ import annotations
import argparse,hashlib,importlib.metadata,importlib.util,json,platform,subprocess,sys,time
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
SOURCE_COMMIT="878940245562bcd1dd0231d78157ba78d70b39f6"
MODEL_REVISION="29e01c4e8d000f4bcd70751be16fa94bf3d85a18"
MODEL_YAML_SHA256="f5a6b2c6f05139d0f18861a1fe506f751e787026b77c05f7e8fef9f8a4405965"

def sha(path):
    h=hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda:f.read(8*1024*1024),b""): h.update(block)
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

def require_metric(metric,max_abs,relative_l2,name):
    if metric.get("finite") is False or float(metric.get("max_abs",999))>max_abs or float(metric.get("relative_l2",999))>relative_l2: raise RuntimeError(f"{name} parity failed: {metric}")

def main():
    p=argparse.ArgumentParser()
    p.add_argument("--asset-root",type=Path,required=True); p.add_argument("--source-root",type=Path,required=True); p.add_argument("--host-receipt",type=Path,required=True)
    p.add_argument("--source-hygiene-receipt",type=Path,required=True); p.add_argument("--acoustic-config-receipt",type=Path,required=True); p.add_argument("--output",type=Path,required=True); a=p.parse_args()
    root=a.asset_root.resolve(); source=a.source_root.resolve(); host_path=a.host_receipt.resolve(); hygiene_path=a.source_hygiene_receipt.resolve(); acoustic_path=a.acoustic_config_receipt.resolve(); out=a.output.resolve()
    head=subprocess.check_output(["git","-C",str(source),"rev-parse","HEAD"],text=True).strip()
    if head!=SOURCE_COMMIT: raise RuntimeError(f"pinned source mismatch: {head}")

    hygiene=load(hygiene_path)
    required_hygiene={"schemaVersion":3,"status":"PASS_SOURCE_HYGIENE","sourceCommit":SOURCE_COMMIT,"matchaSubmoduleCommit":"dd9105b34bf2be2230f4aa1e4769fb586a3c824e","originalGitBlob":"2e0eb4dc5d9216db07207e5564f13a38c4ad2e74","matchaUtilsOriginalGitBlob":"074db6461184e8cbb86d977cb41d9ebd918e958a","matchaPyloggerOriginalGitBlob":"61600678029362e110f655edb91d5f3bc5b1cd1c","acousticConfigRedirected":True,"acousticConfig":"cosyvoice3.acoustic.yaml","runtimeMathChanged":False}
    for key,value in required_hygiene.items():
        if hygiene.get(key)!=value: raise RuntimeError(f"source hygiene receipt mismatch {key}: {hygiene.get(key)!r}")
    exporter=source/str(hygiene.get("target","")); matcha=source/"third_party/Matcha-TTS"; matcha_utils=matcha/str(hygiene.get("matchaUtilsTarget","")); matcha_pylogger=matcha/str(hygiene.get("matchaPyloggerTarget",""))
    if not exporter.is_file() or "/Volumes/WD/Codes/CosyVoice3/.venv-upstream" in exporter.read_text() or "MODEL/'cosyvoice3.acoustic.yaml'" not in exporter.read_text(): raise RuntimeError("sanitized acoustic exporter mismatch")
    if not matcha_utils.is_file() or matcha_utils.read_text()!="from matcha.utils.pylogger import get_pylogger\n": raise RuntimeError("Matcha utils hygiene mismatch")
    if not matcha_pylogger.is_file() or "lightning" in matcha_pylogger.read_text() or "logging.getLogger" not in matcha_pylogger.read_text(): raise RuntimeError("Matcha pylogger hygiene mismatch")

    acoustic=load(acoustic_path)
    if acoustic.get("schemaVersion")!=1 or acoustic.get("status")!="PASS_ACOUSTIC_CONFIG_DERIVATION" or acoustic.get("sourceSha256")!=MODEL_YAML_SHA256 or acoustic.get("sections")!=["flow","hift"] or acoustic.get("runtimeMathChanged") is not False: raise RuntimeError("acoustic config receipt mismatch")
    acoustic_yaml=Path(acoustic["output"]).resolve()
    if not acoustic_yaml.is_file() or sha(acoustic_yaml)!=acoustic.get("outputSha256"): raise RuntimeError("derived acoustic config hash mismatch")
    acoustic_text=acoustic_yaml.read_text()
    if "flow:" not in acoustic_text or "hift:" not in acoustic_text or any(token in acoustic_text for token in ("cosyvoice.llm","cosyvoice.dataset","cosyvoice.hifigan.hifigan","matcha.hifigan.models","data_pipeline")): raise RuntimeError("derived acoustic config scope mismatch")

    manifest=load(root/"cosyvoice3_fixed225.json"); canonical=load(ROOT/"assets/cosyvoice3_fixed225.example.json"); host=load(host_path); ref=manifest.get("referenceEnrollment") or {}
    if manifest.get("schemaVersion")!=1 or manifest.get("profile")!="ios18-fixed225": raise RuntimeError("rebuilt runtime manifest mismatch")
    for key in ("schemaVersion","profile","tokenizerFolder","textEmbedding","textEmbeddingRows","speechEmbedding","llmPrefill","llmDecode","flowConditions","flowShards","hift","f0Folder","flowMask","flowNoise","ropeTheta"):
        if manifest.get(key)!=canonical.get(key): raise RuntimeError(f"rebuilt canonical asset contract mismatch {key}: {manifest.get(key)!r} != {canonical.get(key)!r}")
    canonical_ref=canonical.get("referenceEnrollment") or {}
    for key in ("speechTokenizer","campPlus","whisperMel128","kaldiMel80","matchaMel80","flowConditionsDynamic","promptTokenCount","promptFrameCount"):
        if ref.get(key)!=canonical_ref.get(key): raise RuntimeError(f"rebuilt reference asset contract mismatch {key}")
    if ref.get("status")!="PASS_HOST_PARITY_REBUILT" or ref.get("devicePromotionRequired") is not True: raise RuntimeError("rebuilt reference lane is not host-parity-only")
    if host.get("schemaVersion")!=2 or host.get("status")!="PASS_HOST_PARITY": raise RuntimeError("rebuilt host parity receipt is not PASS")

    llm=load(source/"iOS/validation/llm_fp16/decode-opt-perlayer/receipt.json")
    if llm.get("status")!="CPU225_COMPLETE" or int(llm.get("argmax_agreements",0))!=225 or float(llm.get("max_decode_abs",1))!=0: raise RuntimeError("LLM full fixed225 CPU replay is not bit-exact")
    for row in llm.get("state_checks") or []:
        for value in (row.get("checks") or {}).values():
            if value.get("prefix_preserved") is not True or value.get("future_untouched") is not True or value.get("finite") is not True: raise RuntimeError("LLM state invariant failed")

    flow_receipts=sorted((source/"iOS/validation/device").glob("flow-fp16-shards-*.json"))
    if not flow_receipts: raise RuntimeError("Flow shard rebuild receipt missing")
    flow=load(flow_receipts[-1])
    if flow.get("status")!="HOST_COREML_VALIDATED" or len(flow.get("packages") or [])!=6: raise RuntimeError("Flow shard host validation is not accepted")
    require_metric(flow.get("torch_shards_vs_full") or {},1e-6,1e-7,"Flow torch shards vs full")
    require_metric(flow.get("sharded_vs_full_fp16_first_call") or {},0,0,"Flow Core ML shards vs monolithic FP16")

    hift=load(source/"iOS/validation/full-pipeline/host-hift-phase-host.json"); f0=load(source/"iOS/validation/full-pipeline/f0-double-export.json")
    if hift.get("status")!="HOST_PHASE_CANDIDATE": raise RuntimeError("HiFT host-phase rebuild receipt is not accepted")
    if f0.get("status")!="EXPORTED_FP64_F0_REFERENCE_WEIGHTS": raise RuntimeError("FP64 F0 rebuild receipt is not accepted")
    require_metric(hift.get("f0_vs_torch") or {},0.005,1e-5,"HiFT F0"); require_metric(hift.get("coreml_chain_vs_torch_fp32_f0") or {},0.03,0.02,"HiFT Core ML chain"); require_metric(hift.get("vs_upstream_fp64_f0") or {},0.03,0.02,"HiFT upstream FP64")

    paths=["cosyvoice3_fixed225.json",manifest["tokenizerFolder"],manifest["textEmbedding"],manifest["speechEmbedding"],manifest["llmPrefill"],manifest["llmDecode"],manifest["flowConditions"],*manifest["flowShards"],manifest["hift"],manifest["f0Folder"],manifest["flowMask"],manifest["flowNoise"],ref["speechTokenizer"],ref["campPlus"],ref["whisperMel128"],ref["kaldiMel80"],ref["matchaMel80"],ref["flowConditionsDynamic"]]
    rows=rows_for(root,paths); xcode=subprocess.check_output(["xcodebuild","-version"],text=True).strip().replace("\n","; ")
    modules={"coremltools":"coremltools","torch":"torch","torchaudio":"torchaudio","numpy":"numpy","transformers":"transformers","onnx":"onnx","onnxruntime":"onnxruntime","HyperPyYAML":"hyperpyyaml","conformer":"conformer","diffusers":"diffusers"}
    versions={dist:importlib.metadata.version(dist) for dist,module in modules.items() if importlib.util.find_spec(module) is not None}
    publication=subprocess.check_output(["git","-C",str(ROOT.parent),"rev-parse","HEAD"],text=True).strip()
    receipt={"schemaVersion":2,"status":"PASS_SUPPORTED_FULL_RUNTIME_REBUILD","engine":"CosyVoice3","platform":"iOS","profile":"ios-fixed225-reference","runtimeProfile":"ios18-fixed225","publicationCommit":publication,"sourceCommit":SOURCE_COMMIT,"modelRevision":MODEL_REVISION,"assetRoot":str(root),"runtimeFileCount":len(rows),"runtimeBytes":sum(r["bytes"] for r in rows),"runtimeTreeSha256":tree_id(rows),"hostParityReceiptSha256":sha(host_path),"sourceHygieneReceiptSha256":sha(hygiene_path),"acousticConfigReceiptSha256":sha(acoustic_path),"acousticConfigSha256":sha(acoustic_yaml),"checks":{"llmFixed225Replay":"PASS_BIT_EXACT","llmStateInvariants":"PASS","flowSixShardHostParity":"PASS_BIT_EXACT_TO_MONOLITHIC_FP16","hiftHostPhase":"PASS_BOUNDED_NUMERICAL","fp64F0Export":"PASS","customReferenceHostParity":"PASS","canonicalAssetValidation":"PASS","canonicalAssetContract":"PASS","sourceHygiene":"PASS","acousticConfigDerivation":"PASS"},"rebuildSemantics":{"supportedRebuild":True,"canonicalByteIdentityClaim":False,"devicePromotionRequiredForRebuiltPackages":True,"fullCheckpointYamlInstantiatedForAcousticConversion":False},"environment":{"platform":platform.platform(),"python":sys.version.split()[0],"xcode":xcode,"packages":versions},"recordedAtUnix":int(time.time())}
    out.parent.mkdir(parents=True,exist_ok=True); out.write_text(json.dumps(receipt,indent=2,sort_keys=True)+"\n"); print("[COSYVOICE3-FULL-REBUILD] PASS "+json.dumps(receipt,sort_keys=True),flush=True)

if __name__=="__main__": main()

# Code purpose: emit Candidate-grade evidence that every shipping fixed225 runtime component can be regenerated from pinned inputs and satisfies the same runtime ABI plus host parity.
# Upstream source: locked CosyVoice3_NPU source, official checkpoint, accepted production converters, canonical asset validator, reference host-parity gate.
# Runtime environment: Apple Silicon macOS, Xcode/Core ML, Python 3.11 pinned rebuild environment.
# Generated: 2026-10-02 America/New_York.
# Changes: verifies pinned source, exact LLM replay/state invariants, six-shard Flow equivalence, bounded HiFT parity, FP64 F0, reference host parity, full runtime ABI, hermetic source hygiene, and SHA-derived Flow+HiFT-only acoustic config without claiming byte identity or device promotion.
