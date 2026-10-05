#!/usr/bin/env python3
#@title check_public_identity.py
# Requirement: Development-only fail-closed public-identity hygiene gate for tracked/release text. Build the private personal identity family at runtime from fragments, cover current/historical usernames, names, separator/host/home/email variants, and preserve SHA-bound historical Git objects rather than rewriting history.
from __future__ import annotations

import argparse
import re
import subprocess
from pathlib import Path

DEFAULT_ROOT = Path(__file__).resolve().parents[1]
SELF = Path(__file__).resolve()

SKIP_DIR_NAMES = {
    ".git",
    ".work",
    ".venv",
    ".venv-assets",
    ".venv-coreml",
    ".venv-rebuild",
    ".venv-release",
    ".venv-upstream",
    "DerivedData",
    "build",
    ".gradle",
    ".cxx",
    "node_modules",
}

TEXT_SUFFIXES = {
    ".c", ".cc", ".cfg", ".cmake", ".cpp", ".gradle", ".h", ".hpp", ".ini", ".java",
    ".js", ".json", ".jsx", ".kt", ".kts", ".m", ".md", ".mm", ".pbxproj",
    ".properties", ".py", ".sh", ".swift", ".toml", ".ts", ".tsx", ".txt",
    ".xml", ".yaml", ".yml",
}
TEXT_BASENAMES = {"README", "LICENSE", "NOTICE", "Makefile", "gradlew"}


def joined(*parts: str) -> str:
    return "".join(parts)


def identity_literals() -> list[str]:
    first = joined("zi", "qi")
    last = joined("zh", "u")
    other = joined("xiao", "dan")
    host = joined(last, "z")
    numbered = joined(host, "0609")
    compact_forward = joined(first, last)
    compact_reverse = joined(last, first)
    dotted_legacy = joined("zi", "gi", ".", last)
    values = {
        first,
        other,
        host,
        numbered,
        compact_forward,
        compact_reverse,
        dotted_legacy,
        joined(first, ".", last),
        joined(first, "_", last),
        joined(first, "-", last),
        joined(last, ".", first),
        joined(last, "_", first),
        joined(last, "-", first),
        joined(first, " ", last),
        joined(last, " ", first),
    }
    return sorted(values, key=lambda value: (-len(value), value))


def patterns() -> list[tuple[str, re.Pattern[str]]]:
    escaped = sorted((re.escape(value) for value in identity_literals()), key=len, reverse=True)
    family = "(?:" + "|".join(escaped) + ")"
    last = re.escape(joined("zh", "u"))
    return [
        (
            "personal identity/account family",
            re.compile(rf"(?<![A-Za-z0-9]){family}(?:[-_.][A-Za-z0-9._-]+)?(?![A-Za-z0-9])", re.IGNORECASE),
        ),
        (
            "personal home path",
            re.compile(rf"(?:/Users|/home)/[^/\s]*(?:{family}|{last})[^/\s]*", re.IGNORECASE),
        ),
        (
            "personal email local-part",
            re.compile(rf"\b[A-Za-z0-9._%+-]*(?:{family})[A-Za-z0-9._%+-]*@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b", re.IGNORECASE),
        ),
    ]

REQUIRED_CANONICAL = {
    "PUBLIC_RELEASE_IDENTITY.md": [
        "actacomes",
        "developer@actacomes.com",
        "actacomes/Cosyvoice",
        "actacomes/CosyVoice-assets",
    ],
    ".mailmap": ["actacomes <developer@actacomes.com>"],
}


def is_text_candidate(path: Path) -> bool:
    return path.name in TEXT_BASENAMES or path.suffix.lower() in TEXT_SUFFIXES


def skipped(relative: Path) -> bool:
    return any(part in SKIP_DIR_NAMES for part in relative.parts)


def candidate_paths(root: Path) -> list[Path]:
    output = subprocess.check_output(
        ["git", "-C", str(root), "ls-files", "-co", "--exclude-standard", "-z"]
    )
    paths: list[Path] = []
    for raw in output.split(b"\0"):
        if not raw:
            continue
        relative = Path(raw.decode("utf-8", errors="surrogateescape"))
        path = root / relative
        if path.is_file() and not skipped(relative):
            paths.append(path)
    return paths


def main() -> int:
    parser=argparse.ArgumentParser()
    parser.add_argument("--root",type=Path,default=DEFAULT_ROOT)
    parser.add_argument("--content-only",action="store_true")
    args=parser.parse_args()
    root=args.root.expanduser().resolve()
    if not (root/".git").exists():
        raise RuntimeError(f"identity scan root is not a Git repository: {root}")

    failures: list[str] = []
    scanned = 0
    compiled = patterns()

    for path in candidate_paths(root):
        if path.resolve() == SELF or not is_text_candidate(path):
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        scanned += 1
        for label, pattern in compiled:
            for match in pattern.finditer(text):
                line = text.count("\n", 0, match.start()) + 1
                failures.append(
                    f"{path.relative_to(root)}:{line}: {label}: {match.group(0)!r}"
                )

    if not args.content_only:
        for relative, required in REQUIRED_CANONICAL.items():
            path = root / relative
            if not path.is_file():
                failures.append(f"{relative}: missing canonical public identity file")
                continue
            text = path.read_text(encoding="utf-8")
            for marker in required:
                if marker not in text:
                    failures.append(f"{relative}: missing canonical marker {marker!r}")

    if failures:
        print("[COSYVOICE3-PUBLIC-IDENTITY] FAIL", flush=True)
        for failure in failures:
            print(f"[COSYVOICE3-PUBLIC-IDENTITY] {failure}", flush=True)
        return 1

    print(
        f"[COSYVOICE3-PUBLIC-IDENTITY] PASS scannedTextFiles={scanned} "
        + ("mode=content-only" if args.content_only else "canonicalName=actacomes canonicalEmail=developer@actacomes.com"),
        flush=True,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

# Purpose: private development-repository identity hygiene before public snapshot/export; personal alias rules are intentionally not public consumer guidance.
# Upstream: PUBLIC_RELEASE_IDENTITY.md, .mailmap and the shared development identity-family policy.
# Runtime: Python 3 standard library + Git.
# Generated: 2026-10-04 America/New_York.
# Changes: expand to the complete identity family including separator/host/home/email variants and surname-only historical home paths, use tracked/non-ignored file enumeration, skip generated .cxx state, and keep retired personal literals out of checker source through runtime fragment assembly.

# Changes 2026-10-04: add --root and --content-only so the exact fresh public snapshot can be scanned with the same complete private-identity family without requiring private release-engineering identity policy files inside the consumer snapshot.
