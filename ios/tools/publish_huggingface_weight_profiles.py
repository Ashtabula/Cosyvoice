#!/usr/bin/env python3
# Requirement: publish the exact validated CosyVoice3 Current/Q8/Hybrid4 iOS profile collection as one immutable private Hugging Face RC.
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import sys
import time
from pathlib import Path

PUBLIC_OWNER = "actacomes"
DEFAULT_REPO_ID = "actacomes/CosyVoice-assets"
DEFAULT_VERSION = "0.3.0-rc1"
PROFILE = "ios-weight-profiles-current-q8-q4hybrid"
DEFAULT_COLLECTION = Path("/Volumes/WD/Codes/Cosyvoice/ios/.work/weight-profile-sdk-q4-hybrid-20261006")
ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "assets" / "releases.json"

PROFILE_CONTRACTS = {
    "current": {
        "displayName": "Cosy Full",
        "manifestSHA256": "2ddc7fa084fb0e458b34f61af7fcc927773fb3697496a17f8ae1593ba33b56ee",
        "payloadTreeSHA256": "4750dba5e727276d22b71399b702a33597aaaf36d61edf8cc3dd8bd3897e6efa",
        "prefillSHA256": "3fe257e2d8659abc7cc6de6c7b17d72510d55ef691f4323410e6bc9a44351c59",
        "decodeSHA256": "c5207c467c19808f14174b239c2a81099970b5c2ba01277720ef985416710d0d",
        "prefillRepresentation": "FP16",
        "decodeRepresentation": "FP16",
        "stateBridgeMode": "shared model-owned FP16 MLState; no cross-model state copy",
        "humanListening": "PASS",
    },
    "q8": {
        "displayName": "Cosy Q8",
        "manifestSHA256": "a276c672e178b4e87d44be96dcb24453bb45b76366270299b5977eca732dc2b5",
        "payloadTreeSHA256": "150c0d45d6133818c782f0dfb4dcb2508f097fc42bc81e12e916aca051954f98",
        "prefillSHA256": "f0b183e1b22a4ffccfc2c95926a0bee921d740543b4b89e40b0894a407b4a280",
        "decodeSHA256": "ce2beac8170a210f3c4d24e4a15b487f5135df69f6a32fdac516183b4ed7c7f5",
        "prefillRepresentation": "INT8 per-channel weight compression",
        "decodeRepresentation": "INT8 per-channel weight compression",
        "stateBridgeMode": "shared model-owned FP16 MLState; no cross-model state copy",
        "humanListening": "PASS",
    },
    "q4": {
        "displayName": "Cosy Hybrid4",
        "manifestSHA256": "4f8e3aec18152c07a0e31814c2fa9ac92c3555fc4345f22f378cc07c6aa495d8",
        "payloadTreeSHA256": "3b57dab13798145f0f4d258c2d0e3903340594ebea85a3775f643e664b83dfd9",
        "prefillSHA256": "f0b183e1b22a4ffccfc2c95926a0bee921d740543b4b89e40b0894a407b4a280",
        "decodeSHA256": "4685dcbfe07df1e06ece018f9e0cd5184405ea29440c2d3ed85e4116bcb9ca46",
        "prefillRepresentation": "Q8 prefill",
        "decodeRepresentation": "INT4 per-channel decode",
        "stateBridgeMode": "Q8-prefill→Q4-decode request-level FP16 state-copy bridge",
        "humanListening": "PASS",
    },
}

P2_CONTRACTS = {
    "group-0.mlpackage": "1b6f04d1b8da6437f2a0da24dba3355050f489ae83a1102e9e40da3ec8334b7a",
    "group-1.mlpackage": "f7c4064e32c19410818034c206b204f8a84c2b6c2a22f664b7d710a3805a017c",
}

FORBIDDEN_MARKERS = (
    "Q4_WEIGHT_ONLY_UNPROMOTED",
    "q4_full_prefill_a",
    "cosyvoice-llm-q4-prefill",
    "cosyvoice-llm-q4-decode",
)

def fail(message: str) -> None:
    raise RuntimeError(message)

def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(8 * 1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

def file_rows(root: Path, *, exclude_names: set[str] | None = None) -> list[dict]:
    exclude_names = exclude_names or set()
    rows = []
    for path in sorted(p for p in root.rglob("*") if p.is_file()):
        if path.name in exclude_names:
            continue
        rel = path.relative_to(root).as_posix()
        rows.append({"path": rel, "bytes": path.stat().st_size, "sha256": sha256_file(path)})
    return rows

def tree_identity(rows: list[dict]) -> str:
    h = hashlib.sha256()
    for row in sorted(rows, key=lambda x: x["path"]):
        h.update(row["path"].encode())
        h.update(b"\0")
        h.update(str(int(row["bytes"])).encode("ascii"))
        h.update(b"\0")
        h.update(row["sha256"].encode("ascii"))
        h.update(b"\n")
    return h.hexdigest()

def package_sha(path: Path) -> str:
    return tree_identity(file_rows(path))

def find_manifest(root: Path) -> Path:
    matches = [root / n for n in ("cosyvoice3_enumerated.json","cosyvoice3_dynamic.json","cosyvoice3_fixed225.json") if (root/n).is_file()]
    if len(matches) != 1:
        fail(f"expected exactly one profile manifest in {root}, found {[p.name for p in matches]}")
    return matches[0]

def profile_paths_from_manifest(root: Path, manifest: dict) -> tuple[Path, Path]:
    prefill = root / str(manifest.get("llmPrefill") or "")
    decode = root / str(manifest.get("llmDecode") or "")
    if not prefill.is_dir() or not decode.is_dir():
        fail(f"prefill/decode packages missing in {root}")
    return prefill, decode

def validate_profile(collection: Path, profile_id: str) -> dict:
    contract = PROFILE_CONTRACTS[profile_id]
    root = collection / profile_id
    if not root.is_dir():
        fail(f"profile root missing: {root}")
    manifest_path = find_manifest(root)
    manifest_bytes = manifest_path.read_bytes()
    manifest_sha = hashlib.sha256(manifest_bytes).hexdigest()
    if manifest_sha != contract["manifestSHA256"]:
        fail(f"{profile_id}: manifest SHA mismatch expected={contract['manifestSHA256']} actual={manifest_sha}")
    manifest = json.loads(manifest_bytes)

    marker = str(manifest.get("experimentalLLMVariant") or "")
    if any(bad in marker for bad in FORBIDDEN_MARKERS):
        fail(f"{profile_id}: forbidden failed Full-Q4 marker found: {marker}")
    if profile_id == "q4" and marker != "Q4_DECODE_HYBRID_A_Q8_PREFILL_INT4_PER_CHANNEL_DECODE":
        fail(f"q4: expected accepted Hybrid4 marker, got {marker!r}")

    prefill, decode = profile_paths_from_manifest(root, manifest)
    prefill_sha = package_sha(prefill)
    decode_sha = package_sha(decode)
    if prefill_sha != contract["prefillSHA256"]:
        fail(f"{profile_id}: prefill package SHA mismatch")
    if decode_sha != contract["decodeSHA256"]:
        fail(f"{profile_id}: decode package SHA mismatch")

    # Match the engine's contentTree identity: exclude the export receipt and .family-build.
    payload_rows = []
    for row in file_rows(root):
        rel = row["path"]
        if rel.endswith("/enumerated-production-export-receipt.json") or rel == "enumerated-production-export-receipt.json":
            continue
        if ".family-build/" in rel or rel.startswith(".family-build/"):
            continue
        payload_rows.append(row)
    payload_sha = tree_identity(payload_rows)
    if payload_sha != contract["payloadTreeSHA256"]:
        fail(f"{profile_id}: payload tree mismatch expected={contract['payloadTreeSHA256']} actual={payload_sha}")

    return {
        "profileID": profile_id,
        **contract,
        "manifestFile": manifest_path.name,
        "payloadBytes": sum(int(x["bytes"]) for x in payload_rows),
    }

def validate_p2(collection: Path) -> list[dict]:
    root = collection / "FlowPartitions" / "p2"
    if not root.is_dir():
        fail(f"shared P2 root missing: {root}")
    out = []
    for name, expected in P2_CONTRACTS.items():
        path = root / name
        if not path.is_dir():
            fail(f"shared P2 package missing: {path}")
        actual = package_sha(path)
        if actual != expected:
            fail(f"P2 {name}: SHA mismatch expected={expected} actual={actual}")
        out.append({"name": name, "sha256": actual, "bytes": sum(r["bytes"] for r in file_rows(path))})
    return out

def validate_collection(collection: Path) -> dict:
    if not collection.is_dir():
        fail(f"collection missing: {collection}")
    for required in ("current","q8","q4","FlowPartitions"):
        if not (collection/required).exists():
            fail(f"collection missing {required}")
    # Do not permit legacy diagnostic roots in the publish collection.
    for path in collection.rglob("*"):
        lower = path.name.lower()
        if "q4_full_prefill" in lower or "block32" in lower:
            fail(f"failed Full-Q4 diagnostic asset found in publish collection: {path}")
    profiles = [validate_profile(collection, p) for p in ("current","q8","q4")]
    p2 = validate_p2(collection)
    collection_rows = file_rows(collection, exclude_names={"hf-profile-collection-manifest.json"})
    return {
        "schemaVersion": 1,
        "engine": "CosyVoice3",
        "platform": "iOS",
        "profileCollection": PROFILE,
        "profiles": profiles,
        "sharedP2": p2,
        "acousticShards": 2,
        "flowSteps": 6,
        "fullQ4PrefillIncluded": False,
        "collectionFileCount": len(collection_rows),
        "collectionBytes": sum(int(x["bytes"]) for x in collection_rows),
        "collectionTreeSha256": tree_identity(collection_rows),
        "validatedCosySourceCommit": "217fd05cc7b63d1ab2a41d4c576a6717dcf4873f",
        "distributionStatus": "PRIVATE_RC",
        "publicRedistributionApproved": False,
    }

def stage(collection: Path, output: Path, version: str) -> tuple[Path, dict]:
    manifest = validate_collection(collection)
    manifest["assetVersion"] = version
    candidate = output.with_name(output.name + ".candidate")
    shutil.rmtree(candidate, ignore_errors=True)
    # Hard-link when possible; copy fallback. Never mutate source.
    try:
        shutil.copytree(collection, candidate, copy_function=os.link)
        copy_mode = "hardlink"
    except Exception:
        shutil.rmtree(candidate, ignore_errors=True)
        shutil.copytree(collection, candidate)
        copy_mode = "copy"
    manifest["stagingMode"] = copy_mode
    manifest_path = candidate / "hf-profile-collection-manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    shutil.rmtree(output, ignore_errors=True)
    output.parent.mkdir(parents=True, exist_ok=True)
    candidate.rename(output)
    return output, manifest

def upload(folder: Path, manifest: dict, repo_id: str, version: str) -> dict:
    try:
        from huggingface_hub import HfApi
    except Exception as exc:
        fail(f"huggingface_hub required: {exc}")
    api = HfApi()
    who = api.whoami()
    username = str((who.get("name") or "") if isinstance(who, dict) else "")
    if username != PUBLIC_OWNER:
        fail(f"HF authenticated identity must be {PUBLIC_OWNER!r}; observed {username!r}")
    api.create_repo(repo_id=repo_id, repo_type="model", private=True, exist_ok=True)
    info = api.repo_info(repo_id=repo_id, repo_type="model")
    if getattr(info, "private", None) is False:
        fail("target Hugging Face repo is public; refusing upload because redistribution gate is still private-RC only")
    remote = f"{REMOTE_ROOT}/{version}"
    commit = api.upload_folder(
        repo_id=repo_id,
        repo_type="model",
        folder_path=str(folder),
        path_in_repo=remote,
        commit_message=f"publish {PROFILE} {version}",
    )
    oid = str(getattr(commit,"oid","") or getattr(commit,"commit_oid","") or getattr(commit,"commit_id","") or "")
    if not re.fullmatch(r"[0-9a-f]{40}", oid):
        fail(f"invalid HF commit oid returned: {oid!r}")
    tag = f"{PROFILE}-v{version}"
    api.create_tag(repo_id=repo_id, repo_type="model", tag=tag, revision=oid, tag_message=f"{PROFILE} {version}", exist_ok=False)
    return {
        "schemaVersion": 1,
        "status": "PASS",
        "owner": PUBLIC_OWNER,
        "repoId": repo_id,
        "repoType": "model",
        "profileCollection": PROFILE,
        "version": version,
        "pathInRepo": remote,
        "revision": oid,
        "tag": tag,
        "visibility": "private",
        "collectionBytes": manifest["collectionBytes"],
        "collectionTreeSha256": manifest["collectionTreeSha256"],
        "profiles": manifest["profiles"],
        "validatedCosySourceCommit": manifest["validatedCosySourceCommit"],
        "uploadedAtUnix": int(time.time()),
    }

def update_catalog(receipt: dict) -> None:
    catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
    row = {
        "profile": receipt["profileCollection"],
        "version": receipt["version"],
        "repoId": receipt["repoId"],
        "repoType": "model",
        "revision": receipt["revision"],
        "pathInRepo": receipt["pathInRepo"],
        "tag": receipt["tag"],
        "distributionStatus": "PRIVATE_RC",
        "requiresAuthentication": True,
        "publicRedistributionApproved": False,
        "licenseGate": "PENDING",
        "minimumIOS": "18.0",
        "candidateTechnicalDistributionReady": True,
        "assetTechnicalStatus": "READY_PRIVATE_RC",
        "sdkIntegrationReady": True,
        "collectionTreeSha256": receipt["collectionTreeSha256"],
        "profiles": [
            {
                "profileID": p["profileID"],
                "displayName": p["displayName"],
                "manifestSHA256": p["manifestSHA256"],
                "payloadTreeSHA256": p["payloadTreeSHA256"],
                "prefillSHA256": p["prefillSHA256"],
                "decodeSHA256": p["decodeSHA256"],
                "humanListening": p["humanListening"],
            }
            for p in receipt["profiles"]
        ],
    }
    releases = [x for x in catalog.get("releases",[]) if not (x.get("profile")==row["profile"] and x.get("version")==row["version"])]
    releases.append(row)
    catalog["releases"] = releases
    CATALOG.write_text(json.dumps(catalog, indent=2, sort_keys=True) + "\n", encoding="utf-8")

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--collection", type=Path, default=DEFAULT_COLLECTION)
    ap.add_argument("--version", default=DEFAULT_VERSION)
    ap.add_argument("--repo-id", default=DEFAULT_REPO_ID)
    ap.add_argument("--output", type=Path)
    ap.add_argument("--upload", action="store_true")
    ap.add_argument("--update-catalog", action="store_true")
    args = ap.parse_args()
    if not re.fullmatch(r"[0-9A-Za-z][0-9A-Za-z._-]*", args.version):
        fail("unsupported version string")
    if args.update_catalog and not args.upload:
        fail("--update-catalog requires --upload")
    collection = args.collection.expanduser().resolve()
    output = (args.output.expanduser().resolve() if args.output else ROOT/".work"/"hf-release"/PROFILE/args.version)
    folder, manifest = stage(collection, output, args.version)
    print("[COSY-PROFILES-HF] VALIDATION_PASS " + json.dumps({
        "collection": str(collection),
        "staged": str(folder),
        "collectionTreeSha256": manifest["collectionTreeSha256"],
        "bytes": manifest["collectionBytes"],
        "profiles": [p["profileID"] for p in manifest["profiles"]],
    }, sort_keys=True), flush=True)
    if not args.upload:
        print("[COSY-PROFILES-HF] PREPARE_ONLY; rerun with --upload", flush=True)
        return 0
    receipt = upload(folder, manifest, args.repo_id, args.version)
    receipt_path = folder.parent / f"{args.version}-hf-upload-receipt.json"
    receipt_path.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    if args.update_catalog:
        update_catalog(receipt)
    print("[COSY-PROFILES-HF] UPLOAD_PASS " + json.dumps(receipt, sort_keys=True), flush=True)
    print(f"[COSY-PROFILES-HF] receipt={receipt_path}", flush=True)
    return 0

if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"[COSY-PROFILES-HF] FAIL {type(exc).__name__}: {exc}", file=sys.stderr, flush=True)
        raise SystemExit(2)

# Code purpose: one-command private-RC publisher for the frozen Current/Q8/Human-approved Hybrid4 profile collection.
# Safety: validates exact manifest/payload/prefill/decode/P2 identities, excludes failed Full-Q4-prefill diagnostics, refuses public HF targets, creates immutable HF commit+tag receipt.
