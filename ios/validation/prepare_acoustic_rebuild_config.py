#@title prepare_acoustic_rebuild_config.py
# Requirement: derive a Flow+HiFT-only HyperPyYAML file from the exact pinned checkpoint config so release conversion never instantiates unrelated LLM/GAN/dataset/training objects.
from __future__ import annotations
import argparse,hashlib,json
from pathlib import Path

EXPECTED_SHA256="f5a6b2c6f05139d0f18861a1fe506f751e787026b77c05f7e8fef9f8a4405965"
SCALAR_KEYS=("sample_rate","spk_embed_dim","token_frame_rate","token_mel_ratio","chunk_size","num_decoding_left_chunks")

def sha256(path:Path)->str:
    h=hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda:f.read(1024*1024),b""): h.update(block)
    return h.hexdigest()

def main():
    p=argparse.ArgumentParser(); p.add_argument("--model-dir",type=Path,required=True); p.add_argument("--output",type=Path,required=True); a=p.parse_args()
    model=a.model_dir.resolve(); source=model/"cosyvoice3.yaml"; output=a.output.resolve()
    actual=sha256(source)
    if actual!=EXPECTED_SHA256: raise RuntimeError(f"pinned cosyvoice3.yaml sha256 mismatch: {actual}")
    text=source.read_text(encoding="utf-8")
    lines=text.splitlines()
    scalar={}
    for line in lines:
        stripped=line.strip()
        for key in SCALAR_KEYS:
            if stripped.startswith(key+":"):
                scalar[key]=line.split("#",1)[0].rstrip()
    missing=[key for key in SCALAR_KEYS if key not in scalar]
    if missing: raise RuntimeError(f"missing required acoustic scalar keys: {missing}")
    flow_start=text.find("\nflow:")
    hift_start=text.find("\nhift:")
    gan_start=text.find("\n# gan related module")
    if min(flow_start,hift_start,gan_start)<0 or not (flow_start<hift_start<gan_start): raise RuntimeError("unexpected pinned config section layout")
    flow=text[flow_start+1:hift_start].rstrip()
    hift=text[hift_start+1:gan_start].rstrip()
    derived="\n".join([scalar[key] for key in SCALAR_KEYS])+"\n\n"+flow+"\n\n"+hift+"\n"
    if any(token in derived for token in ("cosyvoice.llm","cosyvoice.dataset","cosyvoice.hifigan.hifigan","matcha.hifigan.models","parquet_opener","data_pipeline")): raise RuntimeError("non-acoustic object leaked into derived config")
    output.write_text(derived,encoding="utf-8")
    receipt={"schemaVersion":1,"status":"PASS_ACOUSTIC_CONFIG_DERIVATION","source":str(source),"sourceSha256":actual,"output":str(output),"outputSha256":sha256(output),"scalarKeys":list(SCALAR_KEYS),"sections":["flow","hift"],"excluded":["llm","gan wrapper/discriminators","dataset processors","training config"],"runtimeMathChanged":False}
    (output.parent/"cosyvoice3.acoustic.config-receipt.json").write_text(json.dumps(receipt,indent=2,sort_keys=True)+"\n")
    print("[COSYVOICE3-ACOUSTIC-CONFIG] PASS "+json.dumps(receipt,sort_keys=True),flush=True)

if __name__=="__main__": main()

# Code purpose: derive the minimal pinned HyperPyYAML graph needed by iOS Flow/HiFT conversion from the exact checkpoint config.
# Upstream source: FunAudioLLM/Fun-CosyVoice3-0.5B-2512 cosyvoice3.yaml sha256 f5a6b2c6f05139d0f18861a1fe506f751e787026b77c05f7e8fef9f8a4405965.
# Runtime environment: Python 3 standard library in the rebuild venv.
# Generated: 2026-10-02 America/New_York.
# Changes: new file; no copied model parameters beyond exact scalar lines/sections extracted from the pinned checkpoint YAML.
