#!/usr/bin/env python3
#@title rebuild_full_runtime.py
# Requirement: rebuild the complete CosyVoice3 iOS fixed225 runtime from a pinned source/model checkout, never reusing pre-existing converted runtime packages, then assemble and validate the canonical SDK asset contract.
from __future__ import annotations
import argparse,json,os,shutil,subprocess,sys,time
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
SOURCE_COMMIT="878940245562bcd1dd0231d78157ba78d70b39f6"
MODEL_REVISION="29e01c4e8d000f4bcd70751be16fa94bf3d85a18"

def run(cmd, cwd=None, env=None):
    values=[str(v) for v in cmd]; print("[COSYVOICE3-FULL-REBUILD] RUN "+" ".join(values),flush=True)
    subprocess.run(values,cwd=str(cwd) if cwd else None,env=env,check=True)

def require(path):
    p=Path(path)
    if not p.exists(): raise RuntimeError(f"missing rebuild output: {p}")
    return p

def main():
    p=argparse.ArgumentParser()
    p.add_argument("--source-root",type=Path,required=True)
    p.add_argument("--output",type=Path,required=True)
    p.add_argument("--python",default=sys.executable)
    p.add_argument("--force",action="store_true")
    a=p.parse_args()
    source=a.source_root.resolve(); output=a.output.resolve(); py=Path(a.python).resolve()
    if subprocess.check_output(["git","-C",str(source),"rev-parse","HEAD"],text=True).strip()!=SOURCE_COMMIT: raise RuntimeError("pinned source HEAD mismatch")
    model=source/"pretrained_models/Fun-CosyVoice3-0.5B-2512"
    for rel in ("llm.pt","flow.pt","hift.pt","cosyvoice3.yaml","speech_tokenizer_v3.onnx","campplus.onnx"): require(model/rel)
    if output.exists():
        if not a.force: raise RuntimeError(f"output exists; pass --force: {output}")
        shutil.rmtree(output)
    converted=source/"iOS/converted"
    for rel in ("llm_fp16","device-probes","full-pipeline"):
        shutil.rmtree(converted/rel,ignore_errors=True)
    env=os.environ.copy()
    cache=converted/"release-cache"; cache.mkdir(parents=True,exist_ok=True)
    env.update({"NUMBA_CACHE_DIR":str(cache/"numba"),"MPLCONFIGDIR":str(cache/"mpl"),"XDG_CACHE_HOME":str(cache/"xdg")})
    started=time.time()

    run([py,"iOS/tools/optimize_llm_decode.py","--variant","perlayer"],source,env)
    run([py,"iOS/tools/export_llm_mask_write_probe.py","--length","449"],source,env)
    run([py,"iOS/tools/export_llm_mask_write512.py"],source,env)
    run([py,"iOS/tools/export_flow_fp16_shards.py","--export","--validate-coreml"],source,env)
    run([py,"iOS/tools/export_pipeline_acoustics.py"],source,env)
    run([py,"iOS/tools/export_pipeline_acoustics.py","--host-phase"],source,env)
    run([py,"iOS/tools/export_pipeline_acoustics.py","--export-f0-double"],source,env)

    llm=converted/"llm_fp16"; flow=converted/"device-probes"; acoustic=converted/"full-pipeline"
    require(llm/"llm-opt-perlayer-prefill.mlpackage")
    require(llm/"llm-opt-perlayer-decode-maskwrite512.mlpackage")
    for name in ("00-blocks-00-03","01-blocks-04-07","02-blocks-08-11","03-blocks-12-15","04-blocks-16-19","05-blocks-20-21"): require(flow/f"flow-fp16-shard-{name}.mlpackage")
    require(acoustic/"flow-conditions.mlpackage"); require(acoustic/"hift-portable-phase-host-fp32.mlpackage")
    run([py,ROOT/"validation/assemble_fixed225_runtime_from_migration.py","--source-root",source,"--output",output,"--force"],ROOT,env)
    run([py,ROOT/"assets/validate_assets.py","--root",output],ROOT,env)

    receipt={"schemaVersion":1,"status":"PASS_FULL_RUNTIME_REBUILD","sourceCommit":SOURCE_COMMIT,"modelRevision":MODEL_REVISION,"output":str(output),"elapsedSeconds":time.time()-started,
             "steps":["perlayer-llm","maskwrite449","maskwrite512","flow-fp16-six-shard","flow-conditioning","hift-host-phase","fp64-f0","canonical-assembly","asset-validation"],
             "referenceEnrollment":"NOT_INCLUDED_BY_BASE_REBUILD","note":"Reference-enrollment generic assets are rebuilt and parity-gated separately by tools/run_reference_release_mac.sh, then merged into this base runtime before Candidate promotion."}
    rp=output/"full_runtime_rebuild_receipt.json"; rp.write_text(json.dumps(receipt,indent=2,sort_keys=True)+"\n")
    print("[COSYVOICE3-FULL-REBUILD] PASS "+json.dumps(receipt,sort_keys=True),flush=True)

if __name__=="__main__": main()

# Code purpose: deterministic orchestration of the already validated production LLM/Flow/HiFT/F0 conversion chain from pinned inputs into the SDK runtime contract.
# Upstream source: Ashtabula/CosyVoice3_NPU@878940245562bcd1dd0231d78157ba78d70b39f6 and FunAudioLLM/Fun-CosyVoice3-0.5B-2512@29e01c4e8d000f4bcd70751be16fa94bf3d85a18.
# Runtime environment: macOS Apple Silicon, Xcode/Core ML Tools 9-compatible pinned Python environment.
# Generated: 2026-10-02 America/New_York.
# Changes: new file; no existing runtime math is modified.
