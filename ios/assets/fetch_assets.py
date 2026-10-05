#!/usr/bin/env python3
# fetch_assets.py
# Requirement: fetch a CosyVoice3 iOS asset release only from the committed immutable release catalog, verify every byte/tree hash, and atomically activate the complete runtime.
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "assets/releases.json"


def fail(message: str) -> None:
    raise RuntimeError(message)


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


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


def choose(catalog: dict, profile: str | None, version: str | None) -> dict:
    if catalog.get("schemaVersion") != 1 or catalog.get("engine") != "CosyVoice3":
        fail("release catalog identity mismatch")
    if profile is None or version is None:
        default = catalog.get("default")
        if not isinstance(default, dict):
            fail("release catalog has no default; specify --profile and --version")
        profile = profile or default.get("profile")
        version = version or default.get("version")
    matches = [
        row
        for row in catalog.get("releases", [])
        if row.get("profile") == profile and row.get("version") == version
    ]
    if len(matches) != 1:
        fail(f"expected exactly one catalog entry for {profile}/{version}")
    return matches[0]


def validate_release(release: Path, entry: dict) -> dict:
    manifest_path = release / "asset-manifest.json"
    if not manifest_path.is_file():
        fail(f"asset-manifest.json missing: {manifest_path}")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

    for key in ("profile", "assetVersion", "payloadTreeSha256", "testedRuntimeTreeSha256"):
        if not manifest.get(key):
            fail(f"asset manifest missing {key}")
    if manifest["profile"] != entry["profile"] or manifest["assetVersion"] != entry["version"]:
        fail("downloaded manifest profile/version mismatch")
    if manifest["payloadTreeSha256"] != entry["payloadTreeSha256"]:
        fail("downloaded manifest payload tree differs from release catalog")
    if manifest["testedRuntimeTreeSha256"] != entry["testedRuntimeTreeSha256"]:
        fail("downloaded manifest runtime tree differs from release catalog")
    if manifest.get("referenceStatus") != "PASS_DEVICE_PARITY":
        fail("downloaded release is not PASS_DEVICE_PARITY")
    if manifest.get("licenseGate") != entry.get("licenseGate"):
        fail("downloaded license gate differs from release catalog")

    observed = []
    for row in manifest.get("files") or []:
        relative = Path(str(row["path"]))
        path = release / relative
        if not path.is_file():
            fail(f"downloaded file missing: {relative}")
        size = path.stat().st_size
        digest = sha256(path)
        if size != int(row["bytes"]) or digest != row["sha256"]:
            fail(f"downloaded file identity mismatch: {relative}")
        observed.append(
            {"path": relative.as_posix(), "bytes": size, "sha256": digest}
        )

    if len(observed) != int(manifest.get("fileCount", -1)):
        fail("downloaded file count mismatch")
    if tree_identity(observed) != manifest["payloadTreeSha256"]:
        fail("downloaded payloadTreeSha256 mismatch")

    subprocess.run(
        [
            sys.executable,
            str(ROOT / "assets/validate_assets.py"),
            "--root",
            str(release),
            "--require-reference",
        ],
        check=True,
    )
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile")
    parser.add_argument("--version")
    parser.add_argument("--catalog", type=Path, default=CATALOG)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--reuse-valid", action="store_true")
    args = parser.parse_args()

    catalog_path = args.catalog.expanduser().resolve()
    if not catalog_path.is_file():
        fail(f"release catalog missing: {catalog_path}")
    catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
    entry = choose(catalog, args.profile, args.version)

    revision = str(entry.get("revision") or "")
    if len(revision) != 40 or any(char not in "0123456789abcdef" for char in revision):
        fail("release catalog revision must be an exact 40-char lowercase HF commit")
    if entry.get("repoType") != "model":
        fail("only Hugging Face model repos are supported")

    try:
        from huggingface_hub import snapshot_download
    except Exception as error:
        fail(f"huggingface_hub is required: {error}")

    output = args.output.expanduser().resolve()
    if output.exists() and args.reuse_valid:
        try:
            manifest = validate_release(output, entry)
            print(
                "[COSYVOICE3-HF-FETCH] REUSE_PASS "
                + json.dumps(
                    {
                        "output": str(output),
                        "repoId": entry["repoId"],
                        "revision": revision,
                        "profile": entry["profile"],
                        "version": entry["version"],
                        "payloadTreeSha256": manifest["payloadTreeSha256"],
                        "testedRuntimeTreeSha256": manifest["testedRuntimeTreeSha256"],
                    },
                    sort_keys=True,
                ),
                flush=True,
            )
            return
        except Exception as error:
            print(f"[COSYVOICE3-HF-FETCH] existing output is not reusable: {type(error).__name__}: {error}", flush=True)
            if not args.force:
                raise
    if output.exists() and not args.force:
        fail(f"output already exists; pass --force: {output}")

    work = output.with_name("." + output.name + ".download")
    snapshot = work / "snapshot"
    candidate = work / "candidate"
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)

    remote = str(entry["pathInRepo"])
    print(
        f"[COSYVOICE3-HF-FETCH] repo={entry['repoId']} revision={revision} path={remote}",
        flush=True,
    )
    snapshot_download(
        repo_id=entry["repoId"],
        repo_type="model",
        revision=revision,
        allow_patterns=[f"{remote}/**"],
        local_dir=snapshot,
    )

    release = snapshot / remote
    if not release.is_dir():
        fail(f"downloaded release directory missing: {release}")

    release.rename(candidate)
    manifest = validate_release(candidate, entry)

    output.parent.mkdir(parents=True, exist_ok=True)
    backup = output.with_name("." + output.name + ".previous")
    shutil.rmtree(backup, ignore_errors=True)
    if output.exists():
        output.rename(backup)
    try:
        candidate.rename(output)
    except Exception:
        if output.exists():
            shutil.rmtree(output)
        if backup.exists():
            backup.rename(output)
        raise
    shutil.rmtree(backup, ignore_errors=True)
    shutil.rmtree(work, ignore_errors=True)

    print(
        "[COSYVOICE3-HF-FETCH] PASS "
        + json.dumps(
            {
                "output": str(output),
                "repoId": entry["repoId"],
                "revision": revision,
                "profile": entry["profile"],
                "version": entry["version"],
                "payloadTreeSha256": manifest["payloadTreeSha256"],
                "testedRuntimeTreeSha256": manifest["testedRuntimeTreeSha256"],
            },
            sort_keys=True,
        ),
        flush=True,
    )


if __name__ == "__main__":
    main()

# Code purpose: immutable ordinary-developer fetch path for private/public CosyVoice3 iOS asset releases; --catalog permits fail-closed release validation against a temporary candidate catalog before the tracked catalog is committed.
# Runtime: Python3 + huggingface_hub; private RCs require an authenticated Hugging Face token.
# Generated: 2026-10-02 America/New_York.

# Changes 2026-10-04: --reuse-valid rehashes and validates an existing immutable output against the selected catalog entry and returns REUSE_PASS without another Hugging Face download; invalid caches still fail closed unless --force permits replacement.

# Changes 2026-10-04: hide incomplete downloads from Finder and move the exact-revision release into the candidate on the same filesystem, avoiding a redundant multi-GB payload copy; validators and atomic activation remain unchanged.

# Changes 2026-10-05: replacement activation is rollback-safe on the same filesystem; activation failure restores the prior runtime before propagating the error.
