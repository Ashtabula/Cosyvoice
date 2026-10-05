#!/usr/bin/env python3
#@title publish_huggingface_ios_dynamic_n1.py
# Requirement: stage/publish the exact physically accepted CosyVoice3 dynamic N1...479 iOS runtime as a private immutable actacomes Hugging Face RC. Bind runtime bytes to lower-bound, exact public-API and human-listening evidence; never include the validation reference WAV/transcript; never authorize public redistribution without a separate license PASS.
from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parent
PUBLIC_OWNER = "actacomes"
DEFAULT_REPO_ID = "actacomes/CosyVoice-assets"
PROFILE = "ios-dynamic-n1-n479-reference"
RUNTIME_PROFILE = "ios18-dynamic-n1-n479"
DEFAULT_VERSION = "0.2.0-rc1"
MINIMUM_IOS = "18.0"
MODEL_REVISION = "29e01c4e8d000f4bcd70751be16fa94bf3d85a18"


def fail(message: str) -> None:
    raise RuntimeError(message)


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def load_json(path: Path) -> dict:
    if not path.is_file():
        fail(f"missing JSON: {path}")
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        fail(f"JSON object required: {path}")
    return value


def git_head() -> str:
    return subprocess.check_output(["git", "-C", str(REPO), "rev-parse", "HEAD"], text=True).strip()


def assert_runtime_unchanged(validated_commit: str) -> None:
    command = [
        "git", "-C", str(REPO), "diff", "--quiet",
        validated_commit, "HEAD", "--", "ios/Package.swift", "ios/Sources",
    ]
    if subprocess.run(command, check=False).returncode != 0:
        fail(
            "shipping runtime changed after the physical public-API validation commit; "
            "rerun physical dynamic validation before publishing assets"
        )


def clone_copy(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        if destination.is_dir() and not destination.is_symlink():
            shutil.rmtree(destination)
        else:
            destination.unlink()
    if source.is_dir() and not source.is_symlink():
        shutil.copytree(source, destination)
    else:
        shutil.copy2(source, destination)


def file_rows(root: Path) -> list[dict]:
    return [
        {
            "path": path.relative_to(root).as_posix(),
            "bytes": path.stat().st_size,
            "sha256": sha256(path),
        }
        for path in sorted(
            item for item in root.rglob("*")
            if item.is_file() and item.name != "asset-manifest.json"
        )
    ]


def tree_identity(rows: list[dict]) -> str:
    h = hashlib.sha256()
    for row in sorted(rows, key=lambda item: item["path"]):
        h.update(row["path"].encode("utf-8"))
        h.update(b"\0")
        h.update(str(int(row["bytes"])).encode("ascii"))
        h.update(b"\0")
        h.update(row["sha256"].encode("ascii"))
        h.update(b"\n")
    return h.hexdigest()


def append_unique(rows: list[str], value: str | None) -> None:
    if value and value not in rows:
        rows.append(value)


def runtime_paths(fixed: dict, dynamic: dict) -> list[str]:
    rows: list[str] = ["cosyvoice3_fixed225.json", "cosyvoice3_dynamic.json"]

    for manifest in (fixed, dynamic):
        for key in (
            "tokenizerFolder", "textEmbedding", "speechEmbedding", "llmPrefill",
            "llmDecode", "flowConditions", "hift", "f0Folder",
        ):
            append_unique(rows, manifest.get(key))
        for value in manifest.get("flowShards") or []:
            append_unique(rows, value)

    # The fixed manifest is retained because validate_assets.py intentionally checks
    # the fixed ABI first, then activates the dynamic manifest when present.
    append_unique(rows, fixed.get("flowMask"))
    append_unique(rows, fixed.get("flowNoise"))

    contract = dynamic.get("dynamicAcoustic") or {}
    for key in (
        "defaultPromptTokens", "defaultPromptFeat", "defaultSpeaker",
        "flowNoiseMaximum", "hiftExcitationMaximum",
    ):
        append_unique(rows, contract.get(key))

    reference = dynamic.get("referenceEnrollment")
    if not isinstance(reference, dict) or reference.get("status") != "PASS_DEVICE_PARITY":
        fail("dynamic referenceEnrollment is not PASS_DEVICE_PARITY")
    for key in (
        "speechTokenizer", "campPlus", "whisperMel128", "kaldiMel80",
        "matchaMel80", "flowConditionsDynamic",
    ):
        append_unique(rows, reference.get(key))
    return rows


def validate_inputs(args: argparse.Namespace) -> tuple[Path, dict, dict, dict, dict, dict, dict]:
    source = args.source_assets.expanduser().resolve()
    if not source.is_dir():
        fail(f"dynamic source assets missing: {source}")

    subprocess.run(
        [sys.executable, str(ROOT / "assets/validate_assets.py"), "--root", str(source), "--require-reference"],
        check=True,
    )

    fixed = load_json(source / "cosyvoice3_fixed225.json")
    dynamic = load_json(source / "cosyvoice3_dynamic.json")
    candidate = load_json(source / "dynamic-candidate-receipt.json")
    lower = load_json(args.lower_bound_receipt.expanduser().resolve())
    smoke = load_json(args.smoke_receipt.expanduser().resolve())
    listening = load_json(args.listening_receipt.expanduser().resolve())

    if fixed.get("profile") != "ios18-fixed225":
        fail("fixed compatibility manifest mismatch")
    if dynamic.get("schemaVersion") != 2 or dynamic.get("profile") != "ios18-dynamic-n1-n479-candidate":
        fail("dynamic runtime manifest identity mismatch")
    contract = dynamic.get("dynamicAcoustic") or {}
    if [contract.get("speechTokenMinimum"), contract.get("speechTokenMaximum")] != [1, 479]:
        fail("dynamic runtime bounds are not N1...479")
    if candidate.get("status") != "PASS_DYNAMIC_CANDIDATE_ASSET_ROOT_BUILT_NOT_PROMOTED" or candidate.get("NBounds") != [1, 479]:
        fail("dynamic candidate receipt is not accepted N1...479")
    if candidate.get("lowerBoundPhysicalExtensionStatus") != "PASS_N1_N2_LOWER_BOUND_EXTENSION_NOT_PROMOTED":
        fail("dynamic candidate is not bound to lower-bound physical evidence")
    if lower.get("status") != "PASS_N1_N2_LOWER_BOUND_EXTENSION_NOT_PROMOTED" or lower.get("newNBounds") != [1, 479]:
        fail("lower-bound receipt is not accepted N1...479")
    if smoke.get("status") != "PASS_DYNAMIC_PUBLIC_API_DEFAULT_AND_REFERENCE":
        fail("dynamic public-API smoke is not PASS")
    if smoke.get("profile") != "ios18-dynamic-n1-n479-candidate" or smoke.get("speechTokenBounds") != [1, 479]:
        fail("dynamic public-API smoke profile/bounds mismatch")
    validated_commit = str(smoke.get("sourceCommit") or "")
    if not re.fullmatch(r"[0-9a-f]{40}", validated_commit):
        fail("dynamic public-API smoke sourceCommit is invalid")
    assert_runtime_unchanged(validated_commit)
    placement = smoke.get("requestedComputePlacement") or {}
    if placement.get("llmPrefill") != "CPU_ONLY" or placement.get("llmDecode") != "CPU_ONLY":
        fail("dynamic smoke does not prove CPU_ONLY stateful LLM placement")
    if placement.get("dynamicAcoustic") != "CPU_AND_NE":
        fail("dynamic smoke does not prove requested CPU_AND_NE acoustic placement")
    if (smoke.get("dynamicAcousticExecutionHints") or {}).get("reshapeFrequency") != "INFREQUENT":
        fail("dynamic smoke does not prove accepted reshapeFrequency hint")
    if listening.get("status") != "PASS_DYNAMIC_LISTENING_ACCEPTANCE":
        fail("dynamic listening acceptance is not PASS")
    if listening.get("smoke", {}).get("sourceCommit") != validated_commit:
        fail("listening acceptance is not bound to the physical smoke source")
    # The validation reference may identify a real person, but raw reference audio,
    # transcript and derived identity artifacts are deliberately not published.
    return source, fixed, dynamic, candidate, lower, smoke, listening


def stage(args: argparse.Namespace) -> tuple[Path, dict]:
    source, fixed, dynamic, candidate_receipt, lower, smoke, listening = validate_inputs(args)

    license_receipt = load_json(args.license_receipt.expanduser().resolve()) if args.license_receipt else None
    if args.public:
        if license_receipt is None:
            fail("--public requires --license-receipt")
        if license_receipt.get("status") != "PASS" or license_receipt.get("publicRedistributionApproved") is not True:
            fail("license receipt does not authorize public redistribution")
    if args.upload and args.repo_id != DEFAULT_REPO_ID:
        fail(f"Hugging Face repo must be {DEFAULT_REPO_ID}")

    output = (
        args.output.expanduser().resolve()
        if args.output
        else ROOT / ".work" / "hf-release" / PROFILE / args.version
    )
    candidate = output.with_name(output.name + ".candidate")
    shutil.rmtree(candidate, ignore_errors=True)
    candidate.mkdir(parents=True)

    for relative in runtime_paths(fixed, dynamic):
        source_item = source / relative
        if not source_item.exists():
            fail(f"runtime item missing: {source_item}")
        clone_copy(source_item, candidate / relative)

    runtime_rows = file_rows(candidate)
    tested_runtime_tree = tree_identity(runtime_rows)

    # Sanitized machine-readable evidence only. Do not copy validation WAV/transcript.
    evidence_dir = candidate / "release-evidence"
    evidence_dir.mkdir(parents=True, exist_ok=True)
    sanitized_smoke = {
        key: smoke.get(key)
        for key in (
            "schemaVersion", "status", "benchmark", "sourceCommit", "recordedAtUnix",
            "profile", "speechTokenBounds", "flowSteps", "generationContract",
            "requestedComputePlacement", "dynamicAcousticExecutionHints", "default",
            "reference", "device", "deviceModelIdentifier", "systemName",
            "systemVersion", "productionPromotion",
        )
        if key in smoke
    }
    (evidence_dir / "dynamic-public-api-smoke.json").write_text(
        json.dumps(sanitized_smoke, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    sanitized_lower = {
        key: lower.get(key)
        for key in (
            "schemaVersion", "status", "carryForwardBasis",
            "newNBounds", "newTBounds", "newGBounds", "newPCMSampleBounds",
            "physicalCheckpointN", "negativeBoundaryN",
            "priorExhaustiveNBounds", "priorExhaustiveIntegerCount",
            "oldFamilyReceiptSha256", "newFamilyReceiptSha256",
            "equivalenceReceiptSha256", "deviceReceiptSha256",
            "productionPromotion"
        )
        if key in lower
    }
    (evidence_dir / "lower-bound-extension.json").write_text(
        json.dumps(sanitized_lower, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    lanes = listening.get("smoke") or {}
    default_lane = lanes.get("default") or {}
    reference_lane = lanes.get("reference") or {}
    sanitized_listening = {
        "schemaVersion": 1,
        "status": listening.get("status"),
        "profile": lanes.get("profile"),
        "speechTokenBounds": lanes.get("speechTokenBounds"),
        "smokeSourceCommit": lanes.get("sourceCommit"),
        "default": {
            "decision": default_lane.get("decision"),
            "wavSha256": default_lane.get("wavSha256"),
            "N": default_lane.get("N"),
            "samples": default_lane.get("samples"),
        },
        "reference": {
            "decision": reference_lane.get("decision"),
            "identityMatchJudgment": reference_lane.get("identityMatchJudgment"),
            "wavSha256": reference_lane.get("wavSha256"),
            "N": reference_lane.get("N"),
            "samples": reference_lane.get("samples"),
        },
        "distributionBoundary": {
            "referenceMediaIncluded": False,
            "referenceTranscriptIncluded": False,
            "referenceIdentityIncluded": False,
            "publicRedistributionAuthorized": False,
            "meaning": "Human listening acceptance is hash/decision-bound; real-person validation identity/media are excluded from the runtime asset payload."
        }
    }
    (evidence_dir / "listening-acceptance.json").write_text(
        json.dumps(sanitized_listening, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    (evidence_dir / "dynamic-candidate-receipt.json").write_text(
        json.dumps(candidate_receipt, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )

    rows = file_rows(candidate)
    manifest = {
        "schemaVersion": 1,
        "status": "RC" if "-rc" in args.version.lower() else "RELEASE",
        "engine": "CosyVoice3",
        "platform": "iOS",
        "profile": PROFILE,
        "runtimeProfile": RUNTIME_PROFILE,
        "runtimeManifestProfile": dynamic["profile"],
        "assetVersion": args.version,
        "publicOwner": PUBLIC_OWNER,
        "huggingFaceRepoId": args.repo_id,
        "minimumIOS": MINIMUM_IOS,
        "releaseEngineeringCommit": git_head(),
        "validatedRuntimeSourceCommit": smoke["sourceCommit"],
        "modelRevision": MODEL_REVISION,
        "conversionProvenance": {
            "role": "maintainer-only historical asset build provenance; not a clean-room consumer dependency",
            "exportTool": "ios/experiments/dynamic-acoustic/export_full_range_family.py",
            "familyReceiptSha256": candidate_receipt.get("familyReceiptSha256"),
            "lowerBoundExtensionReceiptSha256": candidate_receipt.get("lowerBoundExtensionReceiptSha256"),
            "documentedEnvironment": "macOS arm64; Python 3.11; torch 2.7 family; coremltools 9 family; Xcode coremlcompiler; iOS 18 mlprogram target",
            "exactReleasedPackageAuthority": "immutable per-file SHA256 + payloadTreeSha256 + testedRuntimeTreeSha256",
            "cleanRoomRule": "Candidate/Production consumers fetch and validate immutable assets on macOS; conversion/export is not rerun in clean-room."
        },
        "referenceStatus": "PASS_DEVICE_PARITY",
        "speechTokenBounds": [1, 479],
        "flowFrameBounds": [304, 1260],
        "melFrameBounds": [2, 958],
        "pcmSampleBounds": [960, 459840],
        "sampleRate": 24000,
        "channels": 1,
        "sampleFormat": "Float32",
        "flowStepsDefault": 6,
        "flowStepsSupported": [6, 8, 10],
        "requestedComputePlacement": smoke["requestedComputePlacement"],
        "dynamicAcousticExecutionHints": smoke["dynamicAcousticExecutionHints"],
        "runtimeManifestSha256": sha256(candidate / "cosyvoice3_dynamic.json"),
        "lowerBoundEvidenceSha256": sha256(evidence_dir / "lower-bound-extension.json"),
        "publicApiEvidenceSha256": sha256(evidence_dir / "dynamic-public-api-smoke.json"),
        "listeningEvidenceSha256": sha256(evidence_dir / "listening-acceptance.json"),
        "testedRuntimeTreeSha256": tested_runtime_tree,
        "validationReferenceDistribution": "EXCLUDED",
        "licenseGate": "PASS" if license_receipt is not None else "PENDING",
        "publicRedistributionApproved": bool(license_receipt is not None),
        "fileCount": len(rows),
        "payloadBytes": sum(int(row["bytes"]) for row in rows),
        "payloadTreeSha256": tree_identity(rows),
        "files": rows,
    }
    (candidate / "asset-manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )

    shutil.rmtree(output, ignore_errors=True)
    output.parent.mkdir(parents=True, exist_ok=True)
    candidate.rename(output)
    print("[COSYVOICE3-DYNAMIC-HF] STAGE_PASS " + json.dumps({
        "output": str(output), "profile": PROFILE, "version": args.version,
        "payloadTreeSha256": manifest["payloadTreeSha256"],
        "testedRuntimeTreeSha256": tested_runtime_tree,
        "validatedRuntimeSourceCommit": manifest["validatedRuntimeSourceCommit"],
        "licenseGate": manifest["licenseGate"],
    }, sort_keys=True), flush=True)
    return output, manifest


def upload(args: argparse.Namespace, folder: Path, manifest: dict) -> dict:
    try:
        from huggingface_hub import HfApi
    except Exception as error:
        fail(f"huggingface_hub is required for --upload: {error}")
    api = HfApi()
    who = api.whoami()
    username = str((who.get("name") or who.get("fullname") or "") if isinstance(who, dict) else "")
    if username != PUBLIC_OWNER:
        fail(f"Hugging Face authenticated identity must be {PUBLIC_OWNER}; observed {username!r}")
    api.create_repo(repo_id=args.repo_id, repo_type="model", private=True, exist_ok=True)
    info = api.repo_info(repo_id=args.repo_id, repo_type="model")
    if not args.public and getattr(info, "private", None) is False:
        fail("refusing private RC upload because target repository is public")
    remote = f"{PROFILE}/{args.version}"
    commit = api.upload_folder(
        repo_id=args.repo_id,
        repo_type="model",
        folder_path=str(folder),
        path_in_repo=remote,
        commit_message=f"publish {PROFILE} {args.version}",
    )
    oid = str(
        getattr(commit, "oid", "")
        or getattr(commit, "commit_oid", "")
        or getattr(commit, "commit_id", "")
        or ""
    )
    if not re.fullmatch(r"[0-9a-f]{40}", oid):
        fail(f"Hugging Face upload returned invalid commit oid: {oid!r}")
    tag = f"{PROFILE}-v{args.version}"
    api.create_tag(
        repo_id=args.repo_id, repo_type="model", tag=tag, revision=oid,
        tag_message=f"{PROFILE} {args.version}", exist_ok=False,
    )
    if args.public:
        api.update_repo_settings(repo_id=args.repo_id, repo_type="model", private=False)
    receipt = {
        "schemaVersion": 1,
        "status": "PASS",
        "owner": PUBLIC_OWNER,
        "repoId": args.repo_id,
        "repoType": "model",
        "profile": PROFILE,
        "version": args.version,
        "pathInRepo": remote,
        "commit": oid,
        "tag": tag,
        "visibility": "public" if args.public else "private",
        "payloadBytes": manifest["payloadBytes"],
        "payloadTreeSha256": manifest["payloadTreeSha256"],
        "testedRuntimeTreeSha256": manifest["testedRuntimeTreeSha256"],
        "validatedRuntimeSourceCommit": manifest["validatedRuntimeSourceCommit"],
        "licenseGate": manifest["licenseGate"],
        "uploadedAtUnix": int(time.time()),
    }
    receipt_path = folder.parent / (folder.name + "-hf-upload-receipt.json")
    receipt_path.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print("[COSYVOICE3-DYNAMIC-HF] UPLOAD_PASS " + json.dumps(receipt, sort_keys=True), flush=True)
    return receipt


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", default=DEFAULT_VERSION)
    parser.add_argument("--repo-id", default=DEFAULT_REPO_ID)
    parser.add_argument("--source-assets", type=Path, required=True)
    parser.add_argument("--lower-bound-receipt", type=Path, required=True)
    parser.add_argument("--smoke-receipt", type=Path, required=True)
    parser.add_argument(
        "--listening-receipt", type=Path,
        default=ROOT / "validation/evidence/dynamic_n1_listening_acceptance.json",
    )
    parser.add_argument("--license-receipt", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--upload", action="store_true")
    parser.add_argument("--public", action="store_true")
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9A-Za-z][0-9A-Za-z._-]*", args.version):
        fail("version contains unsupported characters")
    if args.public and not args.upload:
        fail("--public requires --upload")
    folder, manifest = stage(args)
    if args.upload:
        upload(args, folder, manifest)
    else:
        print("[COSYVOICE3-DYNAMIC-HF] PREPARE_ONLY; rerun with --upload for private RC", flush=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"[COSYVOICE3-DYNAMIC-HF] FAIL {type(error).__name__}: {error}", file=sys.stderr, flush=True)
        raise

# Code purpose: stage/upload the exact physically accepted dynamic N1...479 CosyVoice3 iOS runtime as a private immutable Hugging Face RC while excluding validation reference audio/transcript/identity assets.
# Upstream source: exact N1 integration candidate, physical lower-bound evidence, physical default/reference public-API smoke, human listening acceptance, pinned Fun-CosyVoice3 model revision.
# Runtime environment: macOS Apple Silicon Python3; huggingface_hub required only for upload.
# Generated time: 2026-10-04 America/New_York.
# Changes: new dynamic asset publisher; license remains PENDING unless an explicit PASS receipt is supplied.

# Changes 2026-10-04: hosted RC listening evidence is anonymized to decision/output hashes only; real-person validation name, reference WAV/transcript and identity-specific prose are excluded from the asset payload.

# Changes 2026-10-04: immutable dynamic asset manifest records hash-bound family/lower-bound conversion provenance and the exporter-documented macOS/Python/torch/coremltools/Xcode environment, explicitly separating historical model conversion from the supported Mac clean-room consumer path.

# Changes 2026-10-04: hosted lower-bound evidence is sanitized to bounds/checkpoints/cryptographic identity only; developer-local priorSweepPath and other workstation paths are excluded from the immutable asset payload.
