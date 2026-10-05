#@title generate_enumerated_production_assets.sh
# Requirement: fetch/verify the exact frozen CosyVoice3 schema-2 dynamic private RC and generate a new local schema-3 exact EnumeratedShapes N1...450 production-candidate asset root in one foreground command. Never upload, publish, mutate the immutable source RC, or modify release catalog metadata.
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IOS="$ROOT/ios"
PYTHON="${PYTHON:-$IOS/.work/dynamic-acoustic/venv/bin/python}"
PROFILE="ios-dynamic-n1-n479-reference"
VERSION="0.2.0-rc1"
EXPECTED_REVISION="8a1f25460a157f35fe79c42a79946c40a59da08e"
EXPECTED_SHARED_TREE="3f7b9239af32ba5644f1c607aa8a4eb0aa2651454c1b1be7db86ef811c41ab68"
EXPECTED_BRANCH="experiment/ios-enumerated-n1-n450-production"
WORK_ROOT="${COSYVOICE3_ENUMERATED_WORK_ROOT:-$IOS/.work/enumerated-n1-n450}"
SHARED_ROOT="${COSYVOICE3_ENUMERATED_SHARED_ROOT:-$WORK_ROOT/shared-dynamic-rc}"
OUTPUT="${1:-}"
REBUILD_ROOT="${COSYVOICE3_REBUILD_ROOT:-$IOS/.work/rebuild/ios-fixed225-reference}"

fail() {
    printf '[COSY-ENUMERATED-GENERATE] ERROR %s\n' "$1"
    exit 2
}

cd "$ROOT"

command -v git
command -v xcodebuild
command -v xcrun

[ -x "$PYTHON" ] || fail "conversion Python is missing/not executable: $PYTHON"

BRANCH="$(git branch --show-current)"
[ "$BRANCH" = "$EXPECTED_BRANCH" ] || fail "wrong branch: $BRANCH (expected $EXPECTED_BRANCH)"

SOURCE_HEAD="$(git rev-parse HEAD)"
SOURCE_STATUS="$(git status --porcelain)"
if [ -n "$SOURCE_STATUS" ]; then
    printf '[COSY-ENUMERATED-GENERATE] dirty worktree:\n%s\n' "$SOURCE_STATUS"
    fail "source worktree must be clean before asset generation"
fi

if [ -z "$OUTPUT" ]; then
    OUTPUT="$WORK_ROOT/generated-$SOURCE_HEAD"
fi
case "$OUTPUT" in
    /*) ;;
    *) OUTPUT="$ROOT/$OUTPUT" ;;
esac

mkdir -p "$WORK_ROOT"

printf '[COSY-ENUMERATED-GENERATE] sourceHead=%s\n' "$SOURCE_HEAD"
printf '[COSY-ENUMERATED-GENERATE] branch=%s\n' "$BRANCH"
printf '[COSY-ENUMERATED-GENERATE] python=%s\n' "$PYTHON"
printf '[COSY-ENUMERATED-GENERATE] profile=%s/%s\n' "$PROFILE" "$VERSION"
printf '[COSY-ENUMERATED-GENERATE] expectedRevision=%s\n' "$EXPECTED_REVISION"
printf '[COSY-ENUMERATED-GENERATE] expectedSharedTree=%s\n' "$EXPECTED_SHARED_TREE"
printf '[COSY-ENUMERATED-GENERATE] sharedRoot=%s\n' "$SHARED_ROOT"
printf '[COSY-ENUMERATED-GENERATE] rebuildRoot=%s\n' "$REBUILD_ROOT"
printf '[COSY-ENUMERATED-GENERATE] output=%s\n' "$OUTPUT"

FETCH_ARGS=(
    "$IOS/assets/fetch_assets.py"
    --profile "$PROFILE"
    --version "$VERSION"
    --output "$SHARED_ROOT"
    --reuse-valid
)
if [ "${COSYVOICE3_FORCE_SHARED_FETCH:-0}" = "1" ]; then
    FETCH_ARGS+=(--force)
fi

"$PYTHON" "${FETCH_ARGS[@]}"

"$PYTHON" - "$IOS/assets/releases.json" "$SHARED_ROOT/asset-manifest.json" "$EXPECTED_REVISION" "$EXPECTED_SHARED_TREE" <<'PY'
import json
import sys
from pathlib import Path

catalog_path = Path(sys.argv[1])
manifest_path = Path(sys.argv[2])
expected_revision = sys.argv[3]
expected_tree = sys.argv[4]

catalog = json.loads(catalog_path.read_text())
rows = [
    row for row in catalog.get("releases", [])
    if row.get("profile") == "ios-dynamic-n1-n479-reference"
    and row.get("version") == "0.2.0-rc1"
]
if len(rows) != 1:
    raise SystemExit("committed release catalog does not contain exactly one frozen shared RC")
entry = rows[0]
if entry.get("revision") != expected_revision:
    raise SystemExit(f"shared RC revision mismatch: {entry.get('revision')} != {expected_revision}")
if entry.get("payloadTreeSha256") != expected_tree:
    raise SystemExit("shared RC catalog payload tree mismatch")

manifest = json.loads(manifest_path.read_text())
if manifest.get("profile") != "ios-dynamic-n1-n479-reference":
    raise SystemExit("shared RC profile mismatch")
if manifest.get("assetVersion") != "0.2.0-rc1":
    raise SystemExit("shared RC version mismatch")
if manifest.get("payloadTreeSha256") != expected_tree:
    raise SystemExit("shared RC manifest payload tree mismatch")

print(
    "[COSY-ENUMERATED-GENERATE] SHARED_RC_PASS "
    f"revision={expected_revision} profile={manifest.get('profile')} "
    f"version={manifest.get('assetVersion')} payloadTreeSha256={manifest.get('payloadTreeSha256')}",
    flush=True,
)
PY

[ ! -e "$OUTPUT" ] || fail "output already exists: $OUTPUT"

COSYVOICE3_REBUILD_ROOT="$REBUILD_ROOT" PYTHON="$PYTHON" bash "$IOS/validation/build_enumerated_production_candidate.sh"     "$SHARED_ROOT"     "$OUTPUT"

RECEIPT="$OUTPUT/enumerated-production-export-receipt.json"
MANIFEST="$OUTPUT/cosyvoice3_enumerated.json"
[ -s "$RECEIPT" ] || fail "export receipt missing: $RECEIPT"
[ -s "$MANIFEST" ] || fail "schema-3 manifest missing: $MANIFEST"

SUMMARY="$OUTPUT.generation.json"
"$PYTHON" - "$RECEIPT" "$MANIFEST" "$SUMMARY" "$SOURCE_HEAD" "$SHARED_ROOT" "$OUTPUT" <<'PY'
import json
import sys
import time
from pathlib import Path

receipt_path = Path(sys.argv[1])
manifest_path = Path(sys.argv[2])
summary_path = Path(sys.argv[3])
source_head = sys.argv[4]
shared_root = sys.argv[5]
output = sys.argv[6]

receipt = json.loads(receipt_path.read_text())
manifest = json.loads(manifest_path.read_text())

status = str(receipt.get("status", ""))
if not status.startswith("PASS_"):
    raise SystemExit(f"enumerated asset generation did not pass: {status}")
if receipt.get("sourceCommit") != source_head:
    raise SystemExit("export receipt sourceCommit does not match generating HEAD")
if manifest.get("schemaVersion") != 3 or manifest.get("profile") != "ios18-enumerated-n1-n450":
    raise SystemExit("generated manifest is not schema-3 N1...450 enumerated production profile")

contract = manifest.get("enumeratedAcoustic") or {}
if [contract.get("speechTokenMinimum"), contract.get("speechTokenMaximum")] != [1, 450]:
    raise SystemExit("generated speech-token bounds mismatch")

families = [
    [row.get("speechTokenMinimum"), row.get("speechTokenMaximum"), row.get("functionName")]
    for row in contract.get("families") or []
]
expected_families = [
    [1, 128, "n001_128"],
    [129, 256, "n129_256"],
    [257, 384, "n257_384"],
    [385, 450, "n385_450"],
]
if families != expected_families:
    raise SystemExit(f"generated family partition mismatch: {families}")

summary = {
    "schemaVersion": 1,
    "status": "PASS_ENUMERATED_ASSET_GENERATION",
    "sourceCommit": source_head,
    "profile": manifest["profile"],
    "speechTokenBounds": [1, 450],
    "families": families,
    "sharedImmutableRoot": shared_root,
    "generatedAssetRoot": output,
    "payloadBytes": receipt.get("payloadBytes"),
    "payloadFileCount": receipt.get("payloadFileCount"),
    "payloadTreeSha256": receipt.get("payloadTreeSha256"),
    "standaloneRootBytes": receipt.get("standaloneRootBytes"),
    "assetPackageBytes": receipt.get("assetPackageBytes"),
    "productionPromotion": False,
    "uploaded": False,
    "recordedAtUnix": int(time.time()),
}
summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
print("[COSY-ENUMERATED-GENERATE] PASS " + json.dumps(summary, sort_keys=True), flush=True)
PY

printf '[COSY-ENUMERATED-GENERATE] ===== NEXT PHYSICAL COMMAND TEMPLATE =====\n'
printf 'python3 ios/validation/run_enumerated_production_device.py --asset-root %q --device "$DEVICE_ID" --reference-wav "$COSYVOICE3_REFERENCE_WAV" --reference-transcript "$COSYVOICE3_REFERENCE_TRANSCRIPT" --host-receipt "$COSYVOICE3_HOST_RECEIPT" --output "$COSYVOICE3_DEVICE_OUTPUT" --team "$DEVELOPMENT_TEAM"\n' "$OUTPUT"
printf '[COSY-ENUMERATED-GENERATE] generationSummary=%s\n' "$SUMMARY"
printf '[COSY-ENUMERATED-GENERATE] NO_UPLOAD local candidate only\n'

# Code purpose: one-command local generation of the new CosyVoice3 schema-3 N1...450 exact-enumerated asset root: immutable RC fetch/rehash -> pinned conversion/export -> standalone validation -> payload/dedup receipt -> external generation summary.
# Upstream source: ios/assets/fetch_assets.py, ios/validation/build_enumerated_production_candidate.sh, and export_enumerated_production_family.py. Shared model source is actacomes/CosyVoice-assets ios-dynamic-n1-n479-reference/0.2.0-rc1 at immutable revision 8a1f25460a157f35fe79c42a79946c40a59da08e.
# Runtime environment: macOS Apple Silicon; authenticated Hugging Face access for the private shared RC; pinned project Python3.11/torch2.7/coremltools9; Xcode/coremlcompiler.
# Generated time: 2026-10-05 America/New_York.
# Changed lines: new file. No VoxCPM changes, no Hugging Face upload, no release-catalog mutation, no model-math/Flow-step/EOS/public-API change.
