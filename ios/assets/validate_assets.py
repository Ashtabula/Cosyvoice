#!/usr/bin/env python3
# validate_assets.py
import argparse
import json
import sys
from pathlib import Path

def fail(msg):
    raise RuntimeError(msg)

def nonempty(path):
    if not path.exists():
        fail(f"missing: {path}")
    if path.is_file() and path.stat().st_size <= 0:
        fail(f"empty: {path}")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True)
    ap.add_argument("--require-reference", action="store_true")
    args = ap.parse_args()
    root = Path(args.root).expanduser().resolve()

    mpath = root / "cosyvoice3_fixed225.json"
    nonempty(mpath)
    m = json.loads(mpath.read_text())
    if m.get("schemaVersion") != 1 or m.get("profile") != "ios18-fixed225":
        fail("manifest identity mismatch")
    if len(m.get("flowShards", [])) != 6:
        fail("expected six Flow shards")
    rows = int(m.get("textEmbeddingRows", 0))
    if rows <= 151646:
        fail("textEmbeddingRows too small for <|endofprompt|>")

    required = [
        m["textEmbedding"], m["speechEmbedding"], m["llmPrefill"], m["llmDecode"],
        m["flowConditions"], m["hift"], m["flowMask"], m["flowNoise"],
        m["f0Folder"], m["tokenizerFolder"], *m["flowShards"]
    ]
    for rel in required:
        nonempty(root / rel)

    if (root / m["textEmbedding"]).stat().st_size != rows * 896 * 2:
        fail("text embedding byte count mismatch")
    if (root / m["speechEmbedding"]).stat().st_size != 6761 * 896 * 2:
        fail("speech embedding byte count mismatch")
    if (root / m["flowMask"]).stat().st_size != 2 * 1 * 752 * 4:
        fail("flow mask byte count mismatch")
    if (root / m["flowNoise"]).stat().st_size != 1 * 80 * 752 * 4:
        fail("flow noise byte count mismatch")

    tokenizer_root = root / m["tokenizerFolder"]
    for name in ("tokenizer_config.json", "tokenizer.json", "vocab.json", "merges.txt"):
        nonempty(tokenizer_root / name)

    tokenizer_data = json.loads((tokenizer_root / "tokenizer.json").read_text(encoding="utf-8"))
    added_tokens = tokenizer_data.get("added_tokens")
    if not isinstance(added_tokens, list):
        fail("tokenizer.json has no added_tokens array")
    added_by_content = {
        item.get("content"): int(item.get("id"))
        for item in added_tokens
        if isinstance(item, dict) and isinstance(item.get("content"), str) and item.get("id") is not None
    }
    if added_by_content.get("<|endofprompt|>") != 151646:
        fail("CosyVoice3 <|endofprompt|> token id must be 151646")
    if added_by_content.get("[ǜ]") != 151923:
        fail("CosyVoice3 final upstream text special token [ǜ] must be id 151923")

    model_vocab = tokenizer_data.get("model", {}).get("vocab")
    if not isinstance(model_vocab, dict) or not model_vocab:
        fail("tokenizer.json model.vocab missing/empty")
    active_text_vocab_rows = max(
        max(int(value) for value in model_vocab.values()),
        max(int(item["id"]) for item in added_tokens),
    ) + 1
    if active_text_vocab_rows != 151924:
        fail(f"CosyVoice3 active text vocab rows mismatch: {active_text_vocab_rows}")
    aligned_rows = ((active_text_vocab_rows + 127) // 128) * 128
    if rows != aligned_rows or rows - active_text_vocab_rows != 12:
        fail(
            "CosyVoice3 text embedding must be the 128-row-aligned physical table: "
            f"active={active_text_vocab_rows} aligned={aligned_rows} manifestRows={rows}"
        )
    f0 = root / m["f0Folder"]
    for i in range(5):
        nonempty(f0 / f"f0-{i}-weight.bin")
        nonempty(f0 / f"f0-{i}-bias.bin")
    nonempty(f0 / "f0-classifier-weight.bin")
    nonempty(f0 / "f0-classifier-bias.bin")

    ref = m.get("referenceEnrollment")
    promoted = isinstance(ref, dict) and ref.get("status") == "PASS_DEVICE_PARITY"
    if args.require_reference and not promoted:
        fail("reference enrollment is not PASS_DEVICE_PARITY")
    if promoted:
        if int(ref.get("promptTokenCount", 0)) != 151 or int(ref.get("promptFrameCount", 0)) != 302:
            fail("reference fixed-profile shape mismatch")
        ref_paths = [
            ref["speechTokenizer"], ref["campPlus"], ref["whisperMel128"],
            ref["kaldiMel80"], ref["matchaMel80"], ref["flowConditionsDynamic"]
        ]
        for rel in ref_paths:
            nonempty(root / rel)
        expected_tables = {
            ref["whisperMel128"]: 128 * 201 * 4,
            ref["kaldiMel80"]: 80 * 256 * 4,
            ref["matchaMel80"]: 80 * 961 * 4,
        }
        for rel, expected in expected_tables.items():
            if (root / rel).stat().st_size != expected:
                fail(f"reference table byte count mismatch: {rel}")

    print(
        f"[COSYVOICE3-ASSETS] PASS root={root} profile={m['profile']} "
        f"textRows={rows} referencePromoted={promoted}"
    )

if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"[COSYVOICE3-ASSETS] FAIL {type(exc).__name__}: {exc}", file=sys.stderr)
        raise

# Purpose: fail-closed structural validator for the fixed225 SDK asset profile, exact local CosyVoice3 tokenizer contract, and optional custom-reference lane.
# Generated: 2026-10-02 America/New_York.
