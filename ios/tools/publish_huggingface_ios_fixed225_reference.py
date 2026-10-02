#!/usr/bin/env python3
#@title publish_huggingface_ios_fixed225_reference.py
# Requirement: stage and publish the complete promoted CosyVoice3 fixed225 iOS runtime as a private actacomes Hugging Face RC, binding the payload to host/device/reference-promotion evidence and refusing public visibility without an explicit redistribution-license PASS.
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
PUBLIC_OWNER = "actacomes"
DEFAULT_REPO_ID = "actacomes/CosyVoice-assets"
PROFILE = "ios-fixed225-reference"
DEFAULT_VERSION = "0.1.0-rc1"
MINIMUM_IOS = "18.0"
UPSTREAM_SOURCE_COMMIT = "878940245562bcd1dd0231d78157ba78d70b39f6"
MODEL_REVISION = "29e01c4e8d000f4bcd70751be16fa94bf3d85a18"
DEFAULT_PROMOTION_RECEIPT = ROOT / "validation/reference-device/promotion-receipt.json"
DEFAULT_LISTENING_RECEIPT = ROOT / "validation/reference-device/listening-acceptance.json"


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
        fail(f"missing JSON file: {path}")
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        fail(f"JSON object required: {path}")
    return value


def git_head() -> str:
    return subprocess.check_output(
        ["git", "-C", str(ROOT.parent), "rev-parse", "HEAD"],
        text=True,
    ).strip()


def clone_copy(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        if destination.is_dir() and not destination.is_symlink():
            shutil.rmtree(destination)
        else:
            destination.unlink()

    if source.is_dir() and not source.is_symlink():
        result = subprocess.run(
            ["cp", "-cR", str(source), str(destination)],
            check=False,
        )
        if result.returncode == 0:
            return
        print(
            f"[COSYVOICE3-HF-PUBLISH] clone-copy unavailable for {source}; falling back to shutil.copytree",
            flush=True,
        )
        shutil.copytree(source, destination)
        return

    result = subprocess.run(
        ["cp", "-c", str(source), str(destination)],
        check=False,
    )
    if result.returncode != 0:
        print(
            f"[COSYVOICE3-HF-PUBLISH] clone-copy unavailable for {source}; falling back to shutil.copy2",
            flush=True,
        )
        shutil.copy2(source, destination)


def file_rows(root: Path) -> list[dict]:
    return [
        {
            "path": path.relative_to(root).as_posix(),
            "bytes": path.stat().st_size,
            "sha256": sha256(path),
        }
        for path in sorted(
            item
            for item in root.rglob("*")
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


def runtime_paths(manifest: dict) -> list[str]:
    reference = manifest.get("referenceEnrollment")
    if not isinstance(reference, dict) or reference.get("status") != "PASS_DEVICE_PARITY":
        fail("canonical runtime referenceEnrollment is not PASS_DEVICE_PARITY")

    rows = [
        "cosyvoice3_fixed225.json",
        manifest["tokenizerFolder"],
        manifest["textEmbedding"],
        manifest["speechEmbedding"],
        manifest["llmPrefill"],
        manifest["llmDecode"],
        manifest["flowConditions"],
        *manifest["flowShards"],
        manifest["hift"],
        manifest["f0Folder"],
        manifest["flowMask"],
        manifest["flowNoise"],
        reference["speechTokenizer"],
        reference["campPlus"],
        reference["whisperMel128"],
        reference["kaldiMel80"],
        reference["matchaMel80"],
        reference["flowConditionsDynamic"],
    ]
    seen = set()
    result = []
    for row in rows:
        if row not in seen:
            result.append(row)
            seen.add(row)
    return result


def validate_device(device: dict, host: dict, host_receipt: Path) -> None:
    if device.get("schemaVersion") != 1:
        fail("device receipt schema mismatch")
    if device.get("status") != "PASS_DEVICE_PUBLIC_API_REFERENCE_PCM":
        fail("device receipt is not PASS_DEVICE_PUBLIC_API_REFERENCE_PCM")
    if device.get("sampleRate") != 24000 or device.get("channels") != 1:
        fail("device receipt output format mismatch")
    if int(device.get("samples", 0)) <= 0 or device.get("finite") is not True:
        fail("device receipt does not prove finite non-empty PCM")
    if float(device.get("peakAbs", 0.0)) <= 1e-6 or float(device.get("rms", 0.0)) <= 1e-7:
        fail("device receipt reports effectively silent PCM")
    if host.get("schemaVersion") != 2 or host.get("status") != "PASS_HOST_PARITY":
        fail("host receipt is not schema-2 PASS_HOST_PARITY")
    expected = sha256(host_receipt)
    if device.get("hostReceiptSha256") != expected:
        fail("device receipt is not bound to the provided PASS_HOST_PARITY receipt")


def validate_promotion(promotion: dict, device_receipt: Path, host_receipt: Path) -> None:
    if promotion.get("schemaVersion") != 1:
        fail("promotion receipt schema mismatch")
    if promotion.get("status") != "PASS_CUSTOM_REFERENCE_DEVICE_PROMOTION":
        fail("custom-reference promotion receipt is not PASS")
    if promotion.get("hostDeviceBindingVerified") is not True:
        fail("promotion receipt does not prove host/device binding")
    if promotion.get("hostReceipt", {}).get("sha256") != sha256(host_receipt):
        fail("promotion receipt host SHA mismatch")
    if promotion.get("deviceReceipt", {}).get("sha256") != sha256(device_receipt):
        fail("promotion receipt device SHA mismatch")


def validate_license(receipt: dict) -> None:
    if receipt.get("schemaVersion") != 1 or receipt.get("status") != "PASS":
        fail("license/redistribution receipt is not schema-1 PASS")
    if receipt.get("profile") not in (PROFILE, "all"):
        fail("license receipt does not cover ios-fixed225-reference")
    if receipt.get("publicRedistributionApproved") is not True:
        fail("license receipt does not approve public redistribution")


def sanitized_device(device: dict) -> dict:
    allowed = (
        "schemaVersion",
        "status",
        "device",
        "systemName",
        "systemVersion",
        "sampleRate",
        "channels",
        "samples",
        "durationSeconds",
        "elapsedSeconds",
        "rtf",
        "finite",
        "peakAbs",
        "rms",
        "referenceTranscriptCharacters",
        "hostReceiptSha256",
    )
    return {key: device.get(key) for key in allowed if key in device}


def stage(args: argparse.Namespace) -> tuple[Path, dict]:
    source = args.source_assets.expanduser().resolve()
    host_receipt = args.host_receipt.expanduser().resolve()
    device_receipt = args.device_receipt.expanduser().resolve()
    promotion_receipt = args.promotion_receipt.expanduser().resolve()
    listening_receipt = args.listening_receipt.expanduser().resolve()

    if not source.is_dir():
        fail(f"source assets missing: {source}")

    subprocess.run(
        [
            sys.executable,
            str(ROOT / "assets/validate_assets.py"),
            "--root",
            str(source),
            "--require-reference",
        ],
        check=True,
    )

    runtime_manifest = load_json(source / "cosyvoice3_fixed225.json")
    if runtime_manifest.get("schemaVersion") != 1 or runtime_manifest.get("profile") != "ios18-fixed225":
        fail("canonical runtime manifest identity mismatch")

    publication = load_json(ROOT / "manifest.json")
    if publication.get("publicApi", {}).get("customReferencePromoted") is not True:
        fail("publication manifest does not mark custom reference promoted")
    if publication.get("fixed225Profile", {}).get("customReference", {}).get("status") != "PASS_DEVICE_PARITY":
        fail("publication manifest custom-reference status is not PASS_DEVICE_PARITY")

    host = load_json(host_receipt)
    device = load_json(device_receipt)
    promotion = load_json(promotion_receipt)
    listening = load_json(listening_receipt)
    validate_device(device, host, host_receipt)
    validate_promotion(promotion, device_receipt, host_receipt)
    if listening.get("status") != "PASS_USER_LISTENING_ACCEPTANCE":
        fail("human listening acceptance is not PASS")

    license_receipt = (
        load_json(args.license_receipt.expanduser().resolve())
        if args.license_receipt
        else None
    )
    if license_receipt is not None:
        validate_license(license_receipt)
    if args.public and license_receipt is None:
        fail("--public requires --license-receipt with public redistribution PASS")
    if args.upload and args.repo_id != DEFAULT_REPO_ID:
        fail(f"Hugging Face repo must be {DEFAULT_REPO_ID}")

    output = (
        args.output.expanduser().resolve()
        if args.output
        else ROOT / ".work/hf-release" / PROFILE / args.version
    )
    candidate = output.with_name(output.name + ".candidate")
    shutil.rmtree(candidate, ignore_errors=True)
    candidate.mkdir(parents=True)

    for relative in runtime_paths(runtime_manifest):
        source_item = source / relative
        if not source_item.exists():
            fail(f"runtime item missing: {source_item}")
        clone_copy(source_item, candidate / relative)

    runtime_rows = file_rows(candidate)
    tested_runtime_tree = tree_identity(runtime_rows)

    (candidate / "device_public_api_receipt.json").write_text(
        json.dumps(sanitized_device(device), indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    clone_copy(promotion_receipt, candidate / "reference_promotion_receipt.json")
    clone_copy(listening_receipt, candidate / "listening_acceptance.json")

    rows = file_rows(candidate)
    manifest = {
        "schemaVersion": 1,
        "status": "RC" if "-rc" in args.version.lower() else "RELEASE",
        "engine": "CosyVoice3",
        "platform": "iOS",
        "profile": PROFILE,
        "runtimeProfile": "ios18-fixed225",
        "assetVersion": args.version,
        "publicOwner": PUBLIC_OWNER,
        "huggingFaceRepoId": args.repo_id,
        "minimumIOS": MINIMUM_IOS,
        "sourceGitCommit": git_head(),
        "upstreamSourceCommit": UPSTREAM_SOURCE_COMMIT,
        "modelRevision": MODEL_REVISION,
        "referenceStatus": "PASS_DEVICE_PARITY",
        "sampleRate": 24000,
        "channels": 1,
        "sampleFormat": "Float32",
        "fixedSpeechTokens": 225,
        "fixedOutputSamples": 216000,
        "fixedOutputSeconds": 9,
        "runtimeManifestSha256": sha256(candidate / "cosyvoice3_fixed225.json"),
        "hostReceiptStatus": host["status"],
        "hostReceiptSha256": sha256(host_receipt),
        "deviceReceipt": "device_public_api_receipt.json",
        "deviceReceiptSha256": sha256(device_receipt),
        "promotionReceipt": "reference_promotion_receipt.json",
        "promotionReceiptSha256": sha256(promotion_receipt),
        "listeningAcceptance": "listening_acceptance.json",
        "testedRuntimeTreeSha256": tested_runtime_tree,
        "licenseGate": "PASS" if license_receipt is not None else "PENDING",
        "publicRedistributionApproved": bool(license_receipt is not None),
        "fileCount": len(rows),
        "payloadBytes": sum(int(row["bytes"]) for row in rows),
        "payloadTreeSha256": tree_identity(rows),
        "files": rows,
    }
    (candidate / "asset-manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    shutil.rmtree(output, ignore_errors=True)
    output.parent.mkdir(parents=True, exist_ok=True)
    candidate.rename(output)

    print(
        "[COSYVOICE3-HF-PUBLISH] STAGE_PASS "
        + json.dumps(
            {
                "output": str(output),
                "profile": PROFILE,
                "version": args.version,
                "payloadBytes": manifest["payloadBytes"],
                "files": manifest["fileCount"],
                "payloadTreeSha256": manifest["payloadTreeSha256"],
                "testedRuntimeTreeSha256": tested_runtime_tree,
                "licenseGate": manifest["licenseGate"],
            },
            sort_keys=True,
        ),
        flush=True,
    )
    return output, manifest


def upload(args: argparse.Namespace, folder: Path, manifest: dict) -> dict:
    try:
        from huggingface_hub import HfApi
    except Exception as error:
        fail(f"huggingface_hub is required for --upload: {error}")

    api = HfApi()
    who = api.whoami()
    username = str(who.get("name") or who.get("user") or "")
    if username != PUBLIC_OWNER:
        fail(
            f"Hugging Face authenticated identity must be {PUBLIC_OWNER}; "
            f"observed {username!r}"
        )

    api.create_repo(
        repo_id=args.repo_id,
        repo_type="model",
        private=True,
        exist_ok=True,
    )
    info = api.repo_info(repo_id=args.repo_id, repo_type="model")
    if not args.public and getattr(info, "private", None) is False:
        fail("refusing private RC upload because target repository is already public")

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
        repo_id=args.repo_id,
        repo_type="model",
        tag=tag,
        revision=oid,
        tag_message=f"{PROFILE} {args.version}",
        exist_ok=False,
    )

    if args.public:
        api.update_repo_settings(
            repo_id=args.repo_id,
            repo_type="model",
            private=False,
        )

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
        "licenseGate": manifest["licenseGate"],
        "uploadedAtUnix": int(time.time()),
    }
    path = folder.parent / (folder.name + "-hf-upload-receipt.json")
    path.write_text(
        json.dumps(receipt, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(
        "[COSYVOICE3-HF-PUBLISH] UPLOAD_PASS "
        + json.dumps(receipt, sort_keys=True),
        flush=True,
    )
    return receipt


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", default=DEFAULT_VERSION)
    parser.add_argument("--repo-id", default=DEFAULT_REPO_ID)
    parser.add_argument("--source-assets", type=Path, required=True)
    parser.add_argument("--host-receipt", type=Path, required=True)
    parser.add_argument("--device-receipt", type=Path, required=True)
    parser.add_argument(
        "--promotion-receipt",
        type=Path,
        default=DEFAULT_PROMOTION_RECEIPT,
    )
    parser.add_argument(
        "--listening-receipt",
        type=Path,
        default=DEFAULT_LISTENING_RECEIPT,
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
        print(
            "[COSYVOICE3-HF-PUBLISH] PREPARE_ONLY "
            "validated promoted runtime staged; rerun with --upload for private RC",
            flush=True,
        )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(
            f"[COSYVOICE3-HF-PUBLISH] FAIL {type(error).__name__}: {error}",
            file=sys.stderr,
            flush=True,
        )
        raise

# Code purpose: stage and upload the complete device-promoted CosyVoice3 fixed225 iOS runtime as an immutable private Hugging Face RC under actacomes.
# Upstream sources: canonical promoted runtime, PASS_HOST_PARITY receipt, physical-iPhone PASS device receipt, and custom-reference promotion evidence.
# Runtime: macOS Python3; huggingface_hub is required only for upload.
# Generated: 2026-10-02 America/New_York.
