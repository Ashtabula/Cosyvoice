#@title fetch_rebuild_checkpoint.py
# Requirement: fetch only checkpoint files required by the fixed225 iOS rebuild into a persistent local directory, verify the exact model revision, reuse interrupted downloads, and link the temporary source checkout to that persistent model directory.
from __future__ import annotations
import argparse,json,os,shutil
from pathlib import Path
from huggingface_hub import HfApi,snapshot_download

ALLOW=[
    "llm.pt","flow.pt","hift.pt","cosyvoice3.yaml","speech_tokenizer_v3.onnx","campplus.onnx",
    "CosyVoice-BlankEN/config.json","CosyVoice-BlankEN/generation_config.json",
    "CosyVoice-BlankEN/tokenizer_config.json","CosyVoice-BlankEN/vocab.json","CosyVoice-BlankEN/merges.txt",
    "CosyVoice-BlankEN/model.safetensors",
]
REQUIRED=[
    "llm.pt","flow.pt","hift.pt","cosyvoice3.yaml","speech_tokenizer_v3.onnx","campplus.onnx",
    "CosyVoice-BlankEN/config.json","CosyVoice-BlankEN/tokenizer_config.json",
    "CosyVoice-BlankEN/vocab.json","CosyVoice-BlankEN/merges.txt","CosyVoice-BlankEN/model.safetensors",
]
UNUSED_LARGE=["llm.rl.pt","flow.decoder.estimator.fp32.onnx","speech_tokenizer_v3.batch.onnx"]

def remove(path:Path):
    if not path.exists() and not path.is_symlink(): return
    if path.is_dir() and not path.is_symlink(): shutil.rmtree(path)
    else: path.unlink()

def main():
    p=argparse.ArgumentParser(); p.add_argument("--source-root",type=Path,required=True); p.add_argument("--model-cache",type=Path,required=True); p.add_argument("--repo",required=True); p.add_argument("--revision",required=True); a=p.parse_args()
    source=a.source_root.resolve(); cache=a.model_cache.expanduser().resolve(); info=HfApi().model_info(a.repo,revision=a.revision)
    if info.sha!=a.revision: raise RuntimeError(f"model revision mismatch {info.sha} != {a.revision}")
    cache.mkdir(parents=True,exist_ok=True)
    snapshot_download(repo_id=a.repo,revision=a.revision,local_dir=cache,allow_patterns=ALLOW)
    missing=[name for name in REQUIRED if not (cache/name).is_file()]
    if missing: raise RuntimeError(f"missing required rebuild model files: {missing}")
    removed=[]
    for name in UNUSED_LARGE:
        path=cache/name
        if path.exists():
            removed.append({"path":name,"bytes":path.stat().st_size}); remove(path)
    dest=source/"pretrained_models/Fun-CosyVoice3-0.5B-2512"; dest.parent.mkdir(parents=True,exist_ok=True); remove(dest); dest.symlink_to(cache,target_is_directory=True)
    lock=source/"iOS/validation/provenance/checkpoint-lock.json"; lock.parent.mkdir(parents=True,exist_ok=True)
    receipt={"schemaVersion":1,"status":"PASS_PINNED_MINIMAL_CHECKPOINT","repo":a.repo,"revision":a.revision,"allowPatterns":ALLOW,"persistentLocalDir":str(cache),"linkedModelDir":str(dest),"removedUnusedLargeFiles":removed}
    lock.write_text(json.dumps(receipt,indent=2,sort_keys=True)+"\n")
    print("[COSYVOICE3-REBUILD] MODEL_PASS "+json.dumps(receipt,sort_keys=True),flush=True)

if __name__=="__main__": main()

# Code purpose: minimize and persist the exact Hugging Face checkpoint subset needed by Candidate full-runtime rebuilds.
# Upstream source: FunAudioLLM/Fun-CosyVoice3-0.5B-2512 pinned model revision.
# Runtime environment: Python 3.11 rebuild venv with huggingface_hub.
# Generated: 2026-10-02 America/New_York.
# Changes: new file; 12 allow-pattern fetch, persistent local_dir reuse, exact revision verification, temporary source symlink, and cleanup of llm.rl.pt / batch tokenizer ONNX / FP32 estimator ONNX when inherited from an earlier whole-repository download.
