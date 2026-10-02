#!/usr/bin/env python3
# export_frontend_tables.py
# Requirement: export the exact fine-tuned Qwen text embedding table and full CosyVoice3 speech/special embedding table as contiguous FP16 little-endian runtime assets.
import argparse, hashlib, json
from pathlib import Path
import numpy as np
import torch

TEXT_KEY="llm.model.model.embed_tokens.weight"
SPEECH_KEY="speech_embedding.weight"

def sha256(path):
    h=hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda:f.read(8*1024*1024),b""): h.update(block)
    return h.hexdigest()

def main():
    p=argparse.ArgumentParser()
    p.add_argument("--llm",type=Path,required=True)
    p.add_argument("--tokenizer-dir",type=Path,required=True)
    p.add_argument("--output",type=Path,required=True)
    p.add_argument("--rope-theta",type=float,required=True)
    a=p.parse_args()
    a.output.mkdir(parents=True,exist_ok=True)
    state=torch.load(a.llm,map_location="cpu",weights_only=True,mmap=True)
    missing=[key for key in (TEXT_KEY,SPEECH_KEY) if key not in state]
    if missing:
        embedding_keys=sorted(key for key in state if "embed" in key.lower())
        raise RuntimeError(
            f"required embedding keys missing: {missing}; available embedding-like keys: {embedding_keys}"
        )
    text=state[TEXT_KEY].detach().cpu().to(torch.float16).contiguous().numpy()
    speech=state[SPEECH_KEY].detach().cpu().to(torch.float16).contiguous().numpy()
    if text.ndim!=2 or text.shape[1]!=896: raise RuntimeError(f"unexpected text embedding shape {text.shape}")
    if tuple(speech.shape)!=(6761,896): raise RuntimeError(f"unexpected speech embedding shape {speech.shape}")
    text_path=a.output/"text_embedding_fp16.bin"; speech_path=a.output/"speech_embedding_fp16.bin"
    text.tofile(text_path); speech.tofile(speech_path)
    tok=a.output/"Tokenizer"; tok.mkdir(exist_ok=True)
    required=["tokenizer_config.json","vocab.json","merges.txt"]
    for name in required:
        src=a.tokenizer_dir/name
        if not src.is_file(): raise FileNotFoundError(src)
        (tok/name).write_bytes(src.read_bytes())
    # swift-transformers normally prefers tokenizer.json; leave generation to transformers if absent.
    if (a.tokenizer_dir/"tokenizer.json").is_file():
        (tok/"tokenizer.json").write_bytes((a.tokenizer_dir/"tokenizer.json").read_bytes())
    receipt={
      "status":"EXPORTED_NOT_DEVICE_VALIDATED","schemaVersion":1,
      "text":{"rows":int(text.shape[0]),"width":896,"dtype":"float16","sha256":sha256(text_path)},
      "speech":{"rows":6761,"width":896,"dtype":"float16","sha256":sha256(speech_path)},
      "ropeTheta":a.rope_theta,
      "sourceKeys":{"text":TEXT_KEY,"speech":SPEECH_KEY}
    }
    (a.output/"frontend_tables_receipt.json").write_text(json.dumps(receipt,indent=2)+"\n")
    print(json.dumps(receipt,indent=2))

if __name__=="__main__": main()

# Purpose: build native Swift embedding assets; Python is build-time only.
# Upstream: pinned llm.pt and CosyVoice-BlankEN tokenizer metadata; speech embedding key matches CosyVoice3_NPU iOS validators: speech_embedding.weight.
# Runtime: host PyTorch/Numpy; output consumed by iOS without Python.
