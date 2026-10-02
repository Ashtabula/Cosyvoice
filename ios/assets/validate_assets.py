#!/usr/bin/env python3
#@title validate_assets.py
# Requirement: fail closed on the fixed225 SDK asset ABI; optionally require generic reference files or full device-promoted reference status.
import argparse,json,sys
from pathlib import Path

def fail(msg): raise RuntimeError(msg)
def nonempty(path):
    if not path.exists(): fail(f"missing: {path}")
    if path.is_file() and path.stat().st_size<=0: fail(f"empty: {path}")

def main():
    ap=argparse.ArgumentParser(); ap.add_argument("--root",required=True); ap.add_argument("--require-reference",action="store_true"); ap.add_argument("--require-reference-files",action="store_true"); args=ap.parse_args()
    root=Path(args.root).expanduser().resolve(); mpath=root/"cosyvoice3_fixed225.json"; nonempty(mpath); m=json.loads(mpath.read_text())
    if m.get("schemaVersion")!=1 or m.get("profile")!="ios18-fixed225": fail("manifest identity mismatch")
    if len(m.get("flowShards",[]))!=6: fail("expected six Flow shards")
    rows=int(m.get("textEmbeddingRows",0))
    if rows<=151646: fail("textEmbeddingRows too small for <|endofprompt|>")
    required=[m["textEmbedding"],m["speechEmbedding"],m["llmPrefill"],m["llmDecode"],m["flowConditions"],m["hift"],m["flowMask"],m["flowNoise"],m["f0Folder"],m["tokenizerFolder"],*m["flowShards"]]
    for rel in required: nonempty(root/rel)
    if (root/m["textEmbedding"]).stat().st_size!=rows*896*2: fail("text embedding byte count mismatch")
    if (root/m["speechEmbedding"]).stat().st_size!=6761*896*2: fail("speech embedding byte count mismatch")
    if (root/m["flowMask"]).stat().st_size!=2*1*752*4: fail("flow mask byte count mismatch")
    if (root/m["flowNoise"]).stat().st_size!=1*80*752*4: fail("flow noise byte count mismatch")
    tokenizer_root=root/m["tokenizerFolder"]
    for name in ("tokenizer_config.json","tokenizer.json","vocab.json","merges.txt"): nonempty(tokenizer_root/name)
    tokenizer_data=json.loads((tokenizer_root/"tokenizer.json").read_text(encoding="utf-8")); added_tokens=tokenizer_data.get("added_tokens")
    if not isinstance(added_tokens,list): fail("tokenizer.json has no added_tokens array")
    added_by_content={item.get("content"):int(item.get("id")) for item in added_tokens if isinstance(item,dict) and isinstance(item.get("content"),str) and item.get("id") is not None}
    if added_by_content.get("<|endofprompt|>")!=151646: fail("CosyVoice3 <|endofprompt|> token id must be 151646")
    if added_by_content.get("[ǜ]")!=151923: fail("CosyVoice3 final upstream text special token [ǜ] must be id 151923")
    model_vocab=tokenizer_data.get("model",{}).get("vocab")
    if not isinstance(model_vocab,dict) or not model_vocab: fail("tokenizer.json model.vocab missing/empty")
    active=max(max(int(v) for v in model_vocab.values()),max(int(item["id"]) for item in added_tokens))+1
    if active!=151924: fail(f"CosyVoice3 active text vocab rows mismatch: {active}")
    aligned=((active+127)//128)*128
    if rows!=aligned or rows-active!=12: fail(f"CosyVoice3 text embedding alignment mismatch active={active} aligned={aligned} manifestRows={rows}")
    f0=root/m["f0Folder"]
    for i in range(5): nonempty(f0/f"f0-{i}-weight.bin"); nonempty(f0/f"f0-{i}-bias.bin")
    nonempty(f0/"f0-classifier-weight.bin"); nonempty(f0/"f0-classifier-bias.bin")
    ref=m.get("referenceEnrollment"); status=ref.get("status") if isinstance(ref,dict) else None; promoted=status=="PASS_DEVICE_PARITY"; rebuilt=status=="PASS_HOST_PARITY_REBUILT"
    if args.require_reference and not promoted: fail("reference enrollment is not PASS_DEVICE_PARITY")
    must_check_reference=promoted or rebuilt or args.require_reference or args.require_reference_files
    if must_check_reference:
        if not isinstance(ref,dict): fail("manifest has no referenceEnrollment contract")
        if status not in ("PASS_DEVICE_PARITY","PASS_HOST_PARITY_REBUILT"): fail(f"reference files requested but status is {status!r}")
        if int(ref.get("promptTokenCount",0))!=151 or int(ref.get("promptFrameCount",0))!=302: fail("reference fixed-profile shape mismatch")
        ref_paths=[ref["speechTokenizer"],ref["campPlus"],ref["whisperMel128"],ref["kaldiMel80"],ref["matchaMel80"],ref["flowConditionsDynamic"]]
        for rel in ref_paths: nonempty(root/rel)
        expected={ref["whisperMel128"]:128*201*4,ref["kaldiMel80"]:80*256*4,ref["matchaMel80"]:80*961*4}
        for rel,size in expected.items():
            if (root/rel).stat().st_size!=size: fail(f"reference table byte count mismatch: {rel}")
    print(f"[COSYVOICE3-ASSETS] PASS root={root} profile={m['profile']} textRows={rows} referenceStatus={status} referenceFilesChecked={must_check_reference}",flush=True)

if __name__=="__main__":
    try: main()
    except Exception as exc:
        print(f"[COSYVOICE3-ASSETS] FAIL {type(exc).__name__}: {exc}",file=sys.stderr); raise

# Code purpose: fail-closed structural validator for base fixed225 assets, exact tokenizer contract, host-parity rebuilt reference assets, and device-promoted reference assets.
# Upstream source: CosyVoice3 iOS canonical fixed225 asset contract.
# Runtime environment: Python 3 standard library.
# Generated: 2026-10-02 America/New_York.
# Changes: adds --require-reference-files for supported rebuilds; validates PASS_HOST_PARITY_REBUILT files without falsely treating them as device-promoted; preserves --require-reference as the stricter PASS_DEVICE_PARITY gate.
