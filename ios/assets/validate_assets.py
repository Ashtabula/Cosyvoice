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

    for name in ("tokenizer_config.json", "vocab.json", "merges.txt"):
        nonempty(root / m["tokenizerFolder"] / name)
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

# Purpose: fail-closed structural validator for the fixed225 SDK asset profile and optional custom-reference lane.
# Generated: 2026-10-02 America/New_York.
