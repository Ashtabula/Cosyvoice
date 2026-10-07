# compare_rebuilt_current_llm_host.py
# Requirement: compare rebuilt Current with the preserved historical LLM on identical frozen inputs; require exact finite logits/hidden/state equality before quantization.
import argparse
import gc
import hashlib
import json
import math
from pathlib import Path
import coremltools as ct
import numpy as np


def rope(positions):
    cosine, sine = [], []
    for position in positions:
        c = [math.cos(position / (1000000.0 ** (2 * i / 64))) for i in range(32)]
        s = [math.sin(position / (1000000.0 ** (2 * i / 64))) for i in range(32)]
        cosine.append(c + c)
        sine.append(s + s)
    shape = (1, 1, len(cosine), 64)
    return np.asarray(cosine, np.float16).reshape(shape), np.asarray(sine, np.float16).reshape(shape)


def capture(root, embeddings, tokens, output, label):
    models = [root / "models" / name for name in
              ("llm-opt-perlayer-prefill.mlpackage", "llm-opt-perlayer-decode-maskwrite512.mlpackage")]
    print("[CURRENT-REBUILD-HOST] load", label, flush=True)
    prefill, decode = [ct.models.MLModel(str(path), compute_units=ct.ComputeUnit.CPU_ONLY) for path in models]
    descriptions = []
    for model in (prefill, decode):
        description = model.get_spec().description
        full = description.SerializeToString(deterministic=True).hex()
        conversion_date = description.metadata.userDefined.get("com.github.apple.coremltools.conversion_date")
        # Retain the diagnosed true rebuild date separately from the otherwise exact ABI.
        if "com.github.apple.coremltools.conversion_date" in description.metadata.userDefined:
            del description.metadata.userDefined["com.github.apple.coremltools.conversion_date"]
        descriptions.append({"full": full, "ABI": description.SerializeToString(deterministic=True).hex(),
                             "actualConversionDate": conversion_date})
    assert len(decode.get_spec().description.state) == 48
    state = prefill.make_state()
    cosine, sine = rope(range(224))
    mask = np.full((1, 1, 224, 224), -65504, np.float16)
    for i in range(224):
        mask[0, 0, i, :i + 1] = 0
    result = prefill.predict({"x": np.asarray(embeddings[tokens[:224]]).reshape(1, 224, 896),
                              "cos": cosine, "sin": sine, "mask": mask}, state=state)
    logits, hidden = [result["logits"].copy()], [result["hidden"].copy()]
    for step in range(64):
        position = 224 + step
        cosine, sine = rope([position])
        mask = np.full((1, 1, 1, 512), -65504, np.float16)
        mask[:, :, :, :position + 1] = 0
        write = np.zeros((1, 1, 512, 1), np.float16)
        write[0, 0, position, 0] = 1
        result = decode.predict({"x": np.asarray(embeddings[tokens[position]]).reshape(1, 1, 896),
                                 "cos": cosine, "sin": sine, "mask": mask, "write_mask": write}, state=state)
        logits.append(result["logits"].copy())
        hidden.append(result["hidden"].copy())
        if (step + 1) % 16 == 0:
            print("[CURRENT-REBUILD-HOST]", label, "decode", step + 1, flush=True)
    values = {"logits": np.asarray(logits), "hidden": np.asarray(hidden)}
    values.update({description.name: state.read_state(description.name).copy()
                   for description in decode.get_spec().description.state})
    assert all(np.isfinite(value).all() for value in values.values())
    np.savez(output / (label + ".npz"), **values)
    del state, prefill, decode, values
    gc.collect()
    return descriptions


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--historical", type=Path, required=True)
    parser.add_argument("--rebuilt", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    embedding_hashes = {}
    for name in ("speech_embedding_fp16.bin", "text_embedding_fp16.bin"):
        old = hashlib.sha256((args.historical / "embeddings" / name).read_bytes()).hexdigest()
        new = hashlib.sha256((args.rebuilt / "embeddings" / name).read_bytes()).hexdigest()
        assert old == new, "rebuilt embedding bytes changed: " + name
        embedding_hashes[name] = new
    tokens = [(i * 37 + 11) % 6500 for i in range(288)]
    embeddings = np.memmap(args.historical / "embeddings/speech_embedding_fp16.bin",
                           dtype=np.float16, mode="r", shape=(6761, 896))
    descriptions = [capture(root, embeddings, tokens, args.output, label)
                    for root, label in [(args.historical, "historical"), (args.rebuilt, "rebuilt")]]
    rows = []
    with np.load(args.output / "historical.npz") as historical, np.load(args.output / "rebuilt.npz") as rebuilt:
        assert set(historical.files) == set(rebuilt.files)
        for key in historical.files:
            a, b = historical[key], rebuilt[key]
            rows.append({"tensor": key, "shape": list(b.shape), "finite": bool(np.isfinite(b).all()),
                         "bitIdentical": bool(np.array_equal(a, b)),
                         "maxAbs": float(np.max(np.abs(a.astype(np.float64) - b.astype(np.float64)))),
                         "rebuiltSHA256": hashlib.sha256(b.tobytes()).hexdigest()})
    abi_equal = all(a["ABI"] == b["ABI"] for a, b in zip(*descriptions))
    full_equal = all(a["full"] == b["full"] for a, b in zip(*descriptions))
    passed = abi_equal and all(row["bitIdentical"] and row["finite"] for row in rows)
    receipt = {"status": "PASS_REBUILT_LLM_SEMANTIC_MATCH" if passed else "FAIL_REBUILT_LLM_SEMANTIC_MATCH",
               "scope": "macOS CPU_ONLY prefill224 + 64 same-input teacher-forced decode, not endpoint PCM or physical proof",
               "descriptionByteIdentical": full_equal, "ABIByteIdenticalExceptRecordedConversionDate": abi_equal,
               "conversionDates": [[x["actualConversionDate"] for x in group] for group in descriptions],
               "embeddingSHA256": embedding_hashes, "stateCount": 48,
               "tokens": tokens, "rows": rows}
    (args.output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print("[CURRENT-REBUILD-HOST]", receipt["status"], flush=True)
    if not passed:
        raise RuntimeError("rebuilt Current differs; quantization gate remains closed")


if __name__ == "__main__":
    main()
# Purpose: strict Current LLM semantic control, without transferring historical audio/device/human evidence.
# Upstream: compare_llm_quantized_host.py frozen input/RoPE/state trajectory and historical Current packages.
# Environment: local macOS Python3.11/coremltools9 CPU_ONLY; generated2026-10-06 America/New_York.
# Changed lines: new validation script; all lines new, zero-error comparison is stricter than approximate characterization.

# Diagnosis2026-10-06: first strict run failed only prefill conversion_date (2026-09-30 vs2026-10-06); all logits/hidden/48 states were bit-identical.
# Only that explicit provenance date is separated from ABI comparison; metadata stays honest, numerical zero-error requirement unchanged, failed receipts preserved.
