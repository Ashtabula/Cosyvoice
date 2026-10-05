#!/usr/bin/env python3
# Requirement: stage a validated CosyVoice3 fixed, RangeDim, or exact-enumerated asset root into DeviceSmoke without mutating canonical assets. Active manifest precedence must match the Swift loader: enumerated > dynamic > fixed.
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "validation/DeviceSmoke/GeneratedAssets"
VALIDATOR = ROOT / "assets/validate_assets.py"
MANIFESTS = ("cosyvoice3_enumerated.json", "cosyvoice3_dynamic.json", "cosyvoice3_fixed225.json")


def run(command: list[str | Path]) -> None:
    values = [str(value) for value in command]
    print("[COSYVOICE3-DEVICE-SMOKE-ASSETS] RUN " + " ".join(values), flush=True)
    subprocess.run(values, check=True)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def select_manifest(runtime: Path) -> tuple[Path, dict]:
    for name in MANIFESTS:
        path = runtime / name
        if path.exists():
            return path, json.loads(path.read_text())
    raise RuntimeError("runtime has no supported CosyVoice3 manifest")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--asset-root", type=Path, required=True)
    parser.add_argument("--host-receipt", type=Path, required=True)
    parser.add_argument("--reference-candidate-dir", type=Path)
    parser.add_argument("--reference-wav", type=Path, required=True)
    parser.add_argument("--reference-transcript", type=Path, required=True)
    parser.add_argument("--candidate-benchmark", action="store_true")
    parser.add_argument("--flow-steps-head-to-head", action="store_true")
    parser.add_argument("--variable-public-api-smoke", action="store_true")
    parser.add_argument("--dynamic-public-api-smoke", action="store_true",
                        help="Compatibility alias for --variable-public-api-smoke.")
    args = parser.parse_args()
    variable_smoke = args.variable_public_api_smoke or args.dynamic_public_api_smoke
    selected_modes = sum(bool(v) for v in (args.candidate_benchmark, args.flow_steps_head_to_head, variable_smoke))
    if selected_modes > 1:
        raise RuntimeError("Candidate benchmark, Flow head-to-head and variable public-API smoke modes are mutually exclusive")

    asset_root = args.asset_root.expanduser().resolve()
    host_receipt_path = args.host_receipt.expanduser().resolve()
    reference_wav = args.reference_wav.expanduser().resolve()
    transcript = args.reference_transcript.expanduser().resolve()
    reference_candidate_dir = args.reference_candidate_dir.expanduser().resolve() if args.reference_candidate_dir else None

    run([sys.executable, VALIDATOR, "--root", asset_root, "--require-reference-files"])
    host = json.loads(host_receipt_path.read_text())
    if host.get("schemaVersion") != 2 or host.get("status") != "PASS_HOST_PARITY":
        raise RuntimeError("host reference parity receipt is not schema-2 PASS_HOST_PARITY")
    if reference_candidate_dir is not None and not reference_candidate_dir.is_dir():
        raise RuntimeError(f"reference candidate directory missing: {reference_candidate_dir}")
    if not reference_wav.is_file():
        raise RuntimeError(f"reference WAV missing: {reference_wav}")
    if not transcript.is_file() or not transcript.read_text(encoding="utf-8").strip():
        raise RuntimeError(f"reference transcript missing/empty: {transcript}")

    if OUTPUT.exists():
        shutil.rmtree(OUTPUT)
    OUTPUT.mkdir(parents=True, exist_ok=True)
    (OUTPUT / ".gitkeep").write_text("", encoding="utf-8")
    runtime = OUTPUT / "Runtime"
    shutil.copytree(asset_root, runtime)
    shutil.copy2(reference_wav, OUTPUT / "reference.wav")
    shutil.copy2(transcript, OUTPUT / "reference.txt")
    shutil.copy2(host_receipt_path, OUTPUT / "reference_host_parity_receipt.json")

    manifest_path, manifest = select_manifest(runtime)
    schema = int(manifest.get("schemaVersion", 0))
    variable_active = schema in (2, 3)
    if schema == 3 and manifest.get("profile") != "ios18-enumerated-n1-n450":
        raise RuntimeError(f"unsupported schema-3 profile: {manifest.get('profile')!r}")
    reference = manifest.get("referenceEnrollment")
    if not isinstance(reference, dict):
        raise RuntimeError("active manifest has no referenceEnrollment contract")

    if reference_candidate_dir is not None:
        candidate_sources = {
            "speechTokenizer": reference_candidate_dir / "speech-tokenizer-fixed605.mlpackage",
            "campPlus": reference_candidate_dir / "campplus-fixed604.mlpackage",
            "whisperMel128": reference_candidate_dir / "whisper_mel_128.f32",
            "kaldiMel80": reference_candidate_dir / "kaldi_mel_80.f32",
            "matchaMel80": reference_candidate_dir / "matcha_mel_80.f32",
        }
        if not variable_active:
            candidate_sources["flowConditionsDynamic"] = reference_candidate_dir / "flow-conditions-dynamic-151-302.mlpackage"
        else:
            if reference.get("flowConditionsDynamic") != manifest.get("flowConditions"):
                raise RuntimeError(
                    "variable-length active manifest must bind referenceEnrollment.flowConditionsDynamic "
                    "to the same generic Conditions package"
                )
        for key, source in candidate_sources.items():
            if not source.exists():
                raise RuntimeError(f"reference candidate missing: {source}")
            destination = runtime / reference[key]
            destination.parent.mkdir(parents=True, exist_ok=True)
            if destination.exists():
                if destination.is_dir():
                    shutil.rmtree(destination)
                else:
                    destination.unlink()
            if source.is_dir():
                shutil.copytree(source, destination)
            else:
                shutil.copy2(source, destination)
            print(
                f"[COSYVOICE3-DEVICE-SMOKE-ASSETS] STAGE {key} "
                f"source={source} destination={destination}",
                flush=True,
            )
        reference["status"] = "PASS_DEVICE_PARITY"
        reference["validationOverride"] = {
            "scope": "DEVICE_SMOKE_STAGED_COPY_ONLY",
            "hostReceiptSha256": sha256(host_receipt_path),
            "canonicalAssetRootMutated": False,
        }
        manifest["referenceEnrollment"] = reference
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    else:
        if reference.get("status") != "PASS_DEVICE_PARITY":
            raise RuntimeError(
                "reference candidate directory omitted but active runtime reference is not already PASS_DEVICE_PARITY"
            )
        if variable_active and reference.get("flowConditionsDynamic") != manifest.get("flowConditions"):
            raise RuntimeError("active variable-length reference Conditions binding mismatch")

    if args.candidate_benchmark or args.flow_steps_head_to_head or variable_smoke:
        source_commit = subprocess.check_output(
            ["git", "-C", str(ROOT.parent), "rev-parse", "HEAD"], text=True
        ).strip()
        if args.candidate_benchmark:
            marker_name, benchmark_name = "candidate-benchmark-mode.json", "public-api-candidate-v1"
        elif args.flow_steps_head_to_head:
            marker_name, benchmark_name = "flow-step-head-to-head-mode.json", "flow-steps-head-to-head-v1"
        else:
            marker_name, benchmark_name = "variable-public-api-smoke-mode.json", "variable-public-api-default-and-reference-v1"
        marker = {
            "schemaVersion": 1,
            "benchmark": benchmark_name,
            "hostReceiptSha256": sha256(host_receipt_path),
            "sourceCommit": source_commit,
            "activeManifest": manifest_path.name,
            "activeProfile": manifest.get("profile"),
        }
        (OUTPUT / marker_name).write_text(json.dumps(marker, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    run([sys.executable, VALIDATOR, "--root", runtime, "--require-reference"])
    print(
        "[COSYVOICE3-DEVICE-SMOKE-ASSETS] PASS "
        f"output={OUTPUT} hostReceiptSha256={sha256(host_receipt_path)} "
        f"activeManifest={manifest_path.name} schema={schema} variableActive={variable_active} "
        "canonicalAssetRootMutated=false",
        flush=True,
    )


if __name__ == "__main__":
    main()

# Code purpose: stage physical-device public-API validation assets with active-manifest semantics identical to CosyVoice3AssetLoader, including the schema-3 exact-enumerated production profile.
# Upstream source: immutable CosyVoice3 asset root plus optional host-parity reference candidate.
# Runtime environment: macOS Python 3 standard library and DeviceSmoke asset staging.
# Generated time: 2026-10-05 America/New_York.
# Changed lines: enumerated > dynamic > fixed precedence; generalized variable smoke marker; optional already-promoted reference asset reuse; schema-3 generic Conditions binding; canonical source remains untouched.
