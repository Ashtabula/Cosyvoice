#@title install_rebuilt_reference_assets.py
# Requirement: install host-parity-validated custom-reference assets into a freshly rebuilt fixed225 runtime without falsely promoting the rebuilt packages to device parity.
from __future__ import annotations
import argparse,hashlib,json,shutil,subprocess,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]; VALIDATOR=ROOT/"assets/validate_assets.py"
def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def copy(src,dst):
    if not src.exists(): raise RuntimeError(f"missing rebuilt reference asset: {src}")
    dst.parent.mkdir(parents=True,exist_ok=True)
    if dst.exists(): shutil.rmtree(dst) if dst.is_dir() and not dst.is_symlink() else dst.unlink()
    shutil.copytree(src,dst) if src.is_dir() else shutil.copy2(src,dst)
def main():
    p=argparse.ArgumentParser(); p.add_argument("--asset-root",type=Path,required=True); p.add_argument("--reference-dir",type=Path,required=True); p.add_argument("--host-receipt",type=Path,required=True); a=p.parse_args()
    root=a.asset_root.resolve(); ref=a.reference_dir.resolve(); host_path=a.host_receipt.resolve(); manifest_path=root/"cosyvoice3_fixed225.json"
    manifest=json.loads(manifest_path.read_text()); host=json.loads(host_path.read_text())
    if manifest.get("profile")!="ios18-fixed225": raise RuntimeError("unexpected runtime profile")
    if host.get("schemaVersion")!=2 or host.get("status")!="PASS_HOST_PARITY": raise RuntimeError("host receipt is not schema-2 PASS_HOST_PARITY")
    enrollment=manifest.get("referenceEnrollment") or {}; mapping={"speechTokenizer":"speech-tokenizer-fixed605.mlpackage","campPlus":"campplus-fixed604.mlpackage","whisperMel128":"whisper_mel_128.f32","kaldiMel80":"kaldi_mel_80.f32","matchaMel80":"matcha_mel_80.f32","flowConditionsDynamic":"flow-conditions-dynamic-151-302.mlpackage"}
    for key,name in mapping.items():
        relative=enrollment.get(key)
        if not relative: raise RuntimeError(f"runtime manifest missing reference path {key}")
        copy(ref/name,root/relative)
    expected={"whisper_mel_128.f32":128*201*4,"kaldi_mel_80.f32":80*256*4,"matcha_mel_80.f32":80*961*4}
    for name,size in expected.items():
        if (ref/name).stat().st_size!=size: raise RuntimeError(f"frontend table size mismatch {name}: {(ref/name).stat().st_size} != {size}")
    enrollment["status"]="PASS_HOST_PARITY_REBUILT"; enrollment["devicePromotionRequired"]=True; enrollment["hostReceiptSha256"]=sha(host_path); manifest["referenceEnrollment"]=enrollment
    manifest_path.write_text(json.dumps(manifest,indent=2)+"\n")
    subprocess.run([sys.executable,str(VALIDATOR),"--root",str(root)],check=True)
    receipt={"schemaVersion":1,"status":"PASS_HOST_PARITY_REBUILT","assetRoot":str(root),"hostReceiptSha256":sha(host_path),"devicePromotionRequired":True,"referenceFiles":{k:{"path":enrollment[k],"sha256":sha(root/enrollment[k]) if (root/enrollment[k]).is_file() else None} for k in mapping}}
    (root/"rebuild_reference_receipt.json").write_text(json.dumps(receipt,indent=2,sort_keys=True)+"\n"); print("[COSYVOICE3-REBUILD-REFERENCE] PASS "+json.dumps(receipt,sort_keys=True),flush=True)
if __name__=="__main__": main()
# Code purpose: merge freshly rebuilt custom-reference packages/tables into a freshly rebuilt base runtime after host parity while keeping device promotion fail-closed.
# Upstream: convert_reference_onnx_to_coreml.py, export_dynamic_flow_conditions.py, run_reference_release_gate.py, assemble_fixed225_runtime_from_migration.py.
# Runtime: macOS Python 3 standard library plus the active rebuild environment.
# Generated: 2026-10-02 America/New_York.
# Changes: new file; validates schema-2 host parity, copies all six reference assets, checks frontend-table byte contracts, marks PASS_HOST_PARITY_REBUILT rather than PASS_DEVICE_PARITY, and re-runs the canonical asset validator.
