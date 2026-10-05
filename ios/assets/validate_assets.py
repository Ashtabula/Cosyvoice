#!/usr/bin/env python3
#@title validate_assets.py
# Requirement: fail closed on exactly one active CosyVoice3 iOS asset profile: schema-1 fixed225, schema-2 RangeDim dynamic, or schema-3 exact EnumeratedShapes N1...450 production architecture. Reference checks follow the active manifest.
import argparse
import json
import sys
from pathlib import Path

ACTIVE_MANIFESTS = (
    "cosyvoice3_enumerated.json",
    "cosyvoice3_dynamic.json",
    "cosyvoice3_fixed225.json",
)
ENUMERATED_FAMILIES = [
    {"speechTokenMinimum": 1, "speechTokenMaximum": 128, "functionName": "n001_128"},
    {"speechTokenMinimum": 129, "speechTokenMaximum": 256, "functionName": "n129_256"},
    {"speechTokenMinimum": 257, "speechTokenMaximum": 384, "functionName": "n257_384"},
    {"speechTokenMinimum": 385, "speechTokenMaximum": 450, "functionName": "n385_450"},
]


def fail(message):
    raise RuntimeError(message)


def nonempty(path: Path):
    if not path.exists():
        fail(f"missing: {path}")
    if path.is_file() and path.stat().st_size <= 0:
        fail(f"empty: {path}")


def active_manifest(root: Path):
    found = [root / name for name in ACTIVE_MANIFESTS if (root / name).exists()]
    if not found:
        fail("no CosyVoice3 asset manifest found")
    selected = next(root / name for name in ACTIVE_MANIFESTS if (root / name).exists())
    return selected, json.loads(selected.read_text())


def validate_shared(root: Path, manifest: dict):
    if len(manifest.get("flowShards", [])) != 6:
        fail("expected six Flow shards")
    rows = int(manifest.get("textEmbeddingRows", 0))
    if rows <= 151646:
        fail("textEmbeddingRows too small for <|endofprompt|>")

    required = [
        manifest["textEmbedding"],
        manifest["speechEmbedding"],
        manifest["llmPrefill"],
        manifest["llmDecode"],
        manifest["flowConditions"],
        manifest["hift"],
        manifest["f0Folder"],
        manifest["tokenizerFolder"],
        *manifest["flowShards"],
    ]
    for relative in required:
        nonempty(root / relative)

    if (root / manifest["textEmbedding"]).stat().st_size != rows * 896 * 2:
        fail("text embedding byte count mismatch")
    if (root / manifest["speechEmbedding"]).stat().st_size != 6761 * 896 * 2:
        fail("speech embedding byte count mismatch")

    tokenizer_root = root / manifest["tokenizerFolder"]
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
    active = max(max(int(v) for v in model_vocab.values()), max(int(item["id"]) for item in added_tokens)) + 1
    aligned = ((active + 127) // 128) * 128
    if active != 151924 or rows != aligned or rows - active != 12:
        fail(f"CosyVoice3 text embedding alignment mismatch active={active} aligned={aligned} manifestRows={rows}")

    f0 = root / manifest["f0Folder"]
    for index in range(5):
        nonempty(f0 / f"f0-{index}-weight.bin")
        nonempty(f0 / f"f0-{index}-bias.bin")
    nonempty(f0 / "f0-classifier-weight.bin")
    nonempty(f0 / "f0-classifier-bias.bin")
    return rows


def validate_fixed(root: Path, manifest: dict):
    if manifest.get("schemaVersion") != 1 or manifest.get("profile") != "ios18-fixed225":
        fail("fixed225 manifest identity mismatch")
    flow_mask = manifest.get("flowMask")
    flow_noise = manifest.get("flowNoise")
    if not flow_mask or not flow_noise:
        fail("fixed225 manifest requires flowMask and flowNoise")
    nonempty(root / flow_mask)
    nonempty(root / flow_noise)
    if (root / flow_mask).stat().st_size != 2 * 1 * 752 * 4:
        fail("fixed225 flow mask byte count mismatch")
    if (root / flow_noise).stat().st_size != 1 * 80 * 752 * 4:
        fail("fixed225 flow noise byte count mismatch")


def validate_dynamic(root: Path, manifest: dict):
    if manifest.get("schemaVersion") != 2 or not str(manifest.get("profile", "")).startswith("ios18-dynamic-"):
        fail("dynamic manifest identity mismatch")
    contract = manifest.get("dynamicAcoustic")
    if not isinstance(contract, dict):
        fail("dynamic manifest has no dynamicAcoustic contract")
    if contract.get("status") not in ("CANDIDATE", "PASS_DEVICE_VALIDATION"):
        fail(f"unsupported dynamic acoustic status: {contract.get('status')!r}")
    nmin = int(contract.get("speechTokenMinimum", 0))
    nmax = int(contract.get("speechTokenMaximum", 0))
    prompt = int(contract.get("promptFrameCount", 0))
    if nmin < 1 or nmax < nmin or nmax > 512 or prompt != 302:
        fail(f"invalid dynamic bounds N={nmin}...{nmax} P={prompt}")
    validate_variable_buffers(root, contract, nmax, prompt, "dynamic")


def validate_enumerated(root: Path, manifest: dict):
    if manifest.get("schemaVersion") != 3 or manifest.get("profile") != "ios18-enumerated-n1-n450":
        fail("enumerated manifest identity mismatch")
    contract = manifest.get("enumeratedAcoustic")
    if not isinstance(contract, dict):
        fail("enumerated manifest has no enumeratedAcoustic contract")
    if contract.get("status") not in ("CANDIDATE", "PASS_DEVICE_VALIDATION"):
        fail(f"unsupported enumerated acoustic status: {contract.get('status')!r}")
    actual = (
        int(contract.get("speechTokenMinimum", 0)),
        int(contract.get("speechTokenMaximum", 0)),
        int(contract.get("promptFrameCount", 0)),
        int(contract.get("logicalPrefixMaximumForFullSpeechWindow", -1)),
    )
    if actual != (1, 450, 302, 62):
        fail(f"invalid enumerated production bounds: {actual}")
    families = contract.get("families")
    if families != ENUMERATED_FAMILIES:
        fail(f"enumerated family partition mismatch: {families!r}")
    if any(int(row["speechTokenMaximum"]) - int(row["speechTokenMinimum"]) + 1 > 128 for row in families):
        fail("enumerated family exceeds Core ML 128-shape limit")
    validate_variable_buffers(root, contract, 450, 302, "enumerated")


def validate_variable_buffers(root: Path, contract: dict, nmax: int, prompt: int, label: str):
    required = [
        contract["defaultPromptTokens"],
        contract["defaultPromptFeat"],
        contract["defaultSpeaker"],
        contract["flowNoiseMaximum"],
        contract["hiftExcitationMaximum"],
    ]
    for relative in required:
        nonempty(root / relative)
    expected = {
        contract["defaultPromptTokens"]: 1 * 151 * 4,
        contract["defaultPromptFeat"]: 1 * 302 * 80 * 4,
        contract["defaultSpeaker"]: 1 * 192 * 4,
        contract["flowNoiseMaximum"]: 1 * 80 * (prompt + 2 * nmax) * 4,
        contract["hiftExcitationMaximum"]: 1 * (960 * nmax) * 9 * 4,
    }
    for relative, size in expected.items():
        actual = (root / relative).stat().st_size
        if actual != size:
            fail(f"{label} asset byte count mismatch: {relative} expected={size} actual={actual}")


def validate_reference(root: Path, manifest: dict, require_reference: bool, require_reference_files: bool):
    reference = manifest.get("referenceEnrollment")
    status = reference.get("status") if isinstance(reference, dict) else None
    promoted = status == "PASS_DEVICE_PARITY"
    rebuilt = status == "PASS_HOST_PARITY_REBUILT"
    if require_reference and not promoted:
        fail("active reference enrollment is not PASS_DEVICE_PARITY")
    must_check = promoted or rebuilt or require_reference or require_reference_files
    if not must_check:
        return status, False
    if not isinstance(reference, dict):
        fail("active manifest has no referenceEnrollment contract")
    if status not in ("PASS_DEVICE_PARITY", "PASS_HOST_PARITY_REBUILT"):
        fail(f"reference files requested but active status is {status!r}")
    if int(reference.get("promptTokenCount", 0)) != 151 or int(reference.get("promptFrameCount", 0)) != 302:
        fail("reference fixed prompt-profile shape mismatch")
    paths = [
        reference["speechTokenizer"],
        reference["campPlus"],
        reference["whisperMel128"],
        reference["kaldiMel80"],
        reference["matchaMel80"],
        reference["flowConditionsDynamic"],
    ]
    for relative in paths:
        nonempty(root / relative)
    expected = {
        reference["whisperMel128"]: 128 * 201 * 4,
        reference["kaldiMel80"]: 80 * 256 * 4,
        reference["matchaMel80"]: 80 * 961 * 4,
    }
    for relative, size in expected.items():
        if (root / relative).stat().st_size != size:
            fail(f"reference table byte count mismatch: {relative}")
    if manifest.get("schemaVersion") in (2, 3) and promoted:
        if reference.get("flowConditionsDynamic") != manifest.get("flowConditions"):
            fail("variable-length reference flowConditionsDynamic must match the active generic Conditions package")
    return status, True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--require-reference", action="store_true")
    parser.add_argument("--require-reference-files", action="store_true")
    args = parser.parse_args()

    root = Path(args.root).expanduser().resolve()
    manifest_path, manifest = active_manifest(root)
    validate_shared(root, manifest)

    schema = manifest.get("schemaVersion")
    if schema == 1:
        validate_fixed(root, manifest)
    elif schema == 2:
        validate_dynamic(root, manifest)
    elif schema == 3:
        validate_enumerated(root, manifest)
    else:
        fail(f"unsupported schemaVersion: {schema!r}")

    status, checked = validate_reference(root, manifest, args.require_reference, args.require_reference_files)
    print(
        f"[COSYVOICE3-ASSETS] PASS root={root} manifest={manifest_path.name} "
        f"profile={manifest.get('profile')} schema={schema} referenceStatus={status} referenceFilesChecked={checked}",
        flush=True,
    )


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"[COSYVOICE3-ASSETS] FAIL {type(exc).__name__}: {exc}", file=sys.stderr)
        raise

# Code purpose: fail-closed standalone asset validation for fixed225, schema-2 RangeDim, and schema-3 exact EnumeratedShapes production roots without requiring one profile to carry another profile's acoustic payload.
# Upstream source: CosyVoice3 iOS asset contracts and immutable dynamic private RC.
# Runtime environment: Python 3 standard library.
# Generated time: 2026-10-05 America/New_York.
# Changed lines: complete profile-neutral validator; schema-3 N1...450/62-prefix/four-family gates; active-manifest reference checks; standalone enumerated roots no longer need fixed225 acoustic assets.
