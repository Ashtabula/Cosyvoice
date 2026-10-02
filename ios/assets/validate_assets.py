#!/usr/bin/env python3
# validate_assets.py
import argparse, json, os, sys
from pathlib import Path

def fail(msg): raise RuntimeError(msg)
def nonempty(p):
    if not p.exists(): fail(f"missing: {p}")
    if p.is_file() and p.stat().st_size<=0: fail(f"empty: {p}")

def main():
    ap=argparse.ArgumentParser(); ap.add_argument("--root",required=True); args=ap.parse_args()
    root=Path(args.root).expanduser().resolve()
    mpath=root/"cosyvoice3_fixed225.json"; nonempty(mpath)
    m=json.loads(mpath.read_text())
    if m.get("schemaVersion")!=1 or m.get("profile")!="ios18-fixed225": fail("manifest identity mismatch")
    if len(m.get("flowShards",[]))!=6: fail("expected six Flow shards")
    rows=int(m.get("textEmbeddingRows",0))
    if rows<=151646: fail("textEmbeddingRows too small for <|endofprompt|>")
    req=[m["textEmbedding"],m["speechEmbedding"],m["llmPrefill"],m["llmDecode"],m["flowConditions"],m["hift"],m["flowMask"],m["flowNoise"],m["f0Folder"],m["tokenizerFolder"],*m["flowShards"]]
    for rel in req: nonempty(root/rel)
    if (root/m["textEmbedding"]).stat().st_size != rows*896*2: fail("text embedding byte count mismatch")
    if (root/m["speechEmbedding"]).stat().st_size != 6761*896*2: fail("speech embedding byte count mismatch")
    if (root/m["flowMask"]).stat().st_size != 2*1*752*4: fail("flow mask byte count mismatch")
    if (root/m["flowNoise"]).stat().st_size != 1*80*752*4: fail("flow noise byte count mismatch")
    for name in ("tokenizer_config.json","vocab.json","merges.txt"): nonempty(root/m["tokenizerFolder"]/name)
    f0=root/m["f0Folder"]
    for i in range(5):
        nonempty(f0/f"f0-{i}-weight.bin"); nonempty(f0/f"f0-{i}-bias.bin")
    nonempty(f0/"f0-classifier-weight.bin"); nonempty(f0/"f0-classifier-bias.bin")
    print(f"[COSYVOICE3-ASSETS] PASS root={root} profile={m['profile']} textRows={rows}")

if __name__=="__main__":
    try: main()
    except Exception as e:
        print(f"[COSYVOICE3-ASSETS] FAIL {type(e).__name__}: {e}",file=sys.stderr); raise

# Purpose: fail-closed structural validator for the fixed225 SDK asset profile.
