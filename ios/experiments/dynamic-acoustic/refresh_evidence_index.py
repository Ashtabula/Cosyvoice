# refresh_evidence_index.py
# Requirement: regenerate the compact tracked evidence index after adding experiment receipts, without hashing itself or any large local .work artifacts.
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--evidence-dir", type=Path, required=True)
    args = parser.parse_args()

    root = args.evidence_dir.resolve()
    rows = {}
    for path in sorted(root.iterdir()):
        if not path.is_file() or path.name == "evidence-index.json":
            continue
        rows[path.name] = {
            "bytes": path.stat().st_size,
            "sha256": digest(path),
        }

    value = {
        "scope": "independent dynamic-acoustic experiment evidence only",
        "files": rows,
        "largeArtifacts": "preserved locally under ios/.work/dynamic-acoustic; not committed",
        "frozenReleaseAssetsAndReceipts": "untouched",
    }

    (root / "evidence-index.json").write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n"
    )
    print(json.dumps(value, indent=2, sort_keys=True), flush=True)


if __name__ == "__main__":
    main()


# Code purpose: keep the committed dynamic-acoustic evidence index synchronized after new small receipts are added.
# Upstream source: ios/experiments/dynamic-acoustic/evidence files only.
# Runtime environment: Python 3 standard library.
# Generated time: 2026-10-03 America/New_York.
# Changes: new experiment-only evidence bookkeeping helper.
