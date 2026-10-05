#@title build_enumerated_production_candidate.sh
# Requirement: one-command local build of the final CosyVoice3 iOS exact EnumeratedShapes N1...450 production-candidate asset root from the already validated immutable schema-2 shared assets. Do not upload or mutate the shared root.
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PYTHON="${PYTHON:-python3}"
SHARED_ROOT="${1:-}"
OUTPUT="${2:-}"

if [ -z "$SHARED_ROOT" ] || [ -z "$OUTPUT" ]; then
    printf 'Usage: PYTHON=/path/to/python bash ios/validation/build_enumerated_production_candidate.sh /path/to/immutable-dynamic-root /path/to/output\n'
    exit 2
fi

case "$SHARED_ROOT" in
    /*) ;;
    *) SHARED_ROOT="$(pwd)/$SHARED_ROOT" ;;
esac
case "$OUTPUT" in
    /*) ;;
    *) OUTPUT="$(pwd)/$OUTPUT" ;;
esac

cd "$ROOT"
SOURCE_HEAD="$(git rev-parse HEAD)"
SOURCE_STATUS="$(git status --porcelain)"
printf '[COSY-ENUMERATED-BUILD] sourceHead=%s\n' "$SOURCE_HEAD"
if [ -n "$SOURCE_STATUS" ]; then
    printf '[COSY-ENUMERATED-BUILD] ERROR tracked/untracked source tree is not clean:\n%s\n' "$SOURCE_STATUS"
    exit 4
fi
printf '[COSY-ENUMERATED-BUILD] sourceTree=clean\n'
printf '[COSY-ENUMERATED-BUILD] python=%s\n' "$PYTHON"
"$PYTHON" --version
printf '[COSY-ENUMERATED-BUILD] sharedRoot=%s\n' "$SHARED_ROOT"
printf '[COSY-ENUMERATED-BUILD] output=%s\n' "$OUTPUT"

if [ -e "$OUTPUT" ]; then
    printf '[COSY-ENUMERATED-BUILD] ERROR output already exists: %s\n' "$OUTPUT"
    exit 3
fi

"$PYTHON" ios/assets/validate_assets.py --root "$SHARED_ROOT" --require-reference
"$PYTHON" ios/experiments/dynamic-acoustic/export_enumerated_production_family.py \
    --shared-root "$SHARED_ROOT" \
    --output "$OUTPUT"
"$PYTHON" ios/assets/validate_assets.py --root "$OUTPUT" --require-reference

printf '[COSY-ENUMERATED-BUILD] ===== RECEIPT =====\n'
cat "$OUTPUT/enumerated-production-export-receipt.json"

printf '[COSY-ENUMERATED-BUILD] ===== SIZE =====\n'
du -sh "$OUTPUT"
du -sh "$OUTPUT/enumerated-acoustic"
find "$OUTPUT/enumerated-acoustic" -maxdepth 1 -name '*.mlpackage' -print -exec du -sh {} \;

printf '[COSY-ENUMERATED-BUILD] ===== MANIFEST =====\n'
cat "$OUTPUT/cosyvoice3_enumerated.json"

printf '[COSY-ENUMERATED-BUILD] PASS output=%s\n' "$OUTPUT"

# Code purpose: execute exporter, standalone fail-closed validation, dedup/size receipt inspection, and final manifest inspection in one foreground command.
# Upstream source: immutable schema-2 CosyVoice3 dynamic private-RC shared assets plus export_enumerated_production_family.py.
# Runtime environment: macOS Apple Silicon with project conversion Python, torch/coremltools/Xcode coremlcompiler.
# Generated time: 2026-10-05 America/New_York.
# Changed lines: new file; no upload, no hidden output, no source mutation, no model parameter or inference-math change.

# Changes 2026-10-05: production asset build now fails closed on any non-clean Git worktree before conversion, so sourceCommit in the export receipt is a complete provenance identity rather than a potentially dirty approximation.
