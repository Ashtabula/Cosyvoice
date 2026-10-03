#@title run_production_prelicense_closure.sh
# Requirement: complete every automatable pre-license Production gate in order: physical clean-room -> non-license evidence commit -> fresh public snapshot -> exact public identity review -> exact asset license inventory, while leaving licensing and public asset publication unresolved.
#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; REPO="$(cd "$ROOT/.." && pwd)"; BRANCH="release/ios-fixed225-sdk-ready"; SNAPSHOT="${COSYVOICE3_PUBLIC_SNAPSHOT_DIR:-$ROOT/.work/public-snapshot/Cosyvoice-public}"
export DEVICE_ID="${DEVICE_ID:-00008150-000A05CA1440401C}"; export DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-H5R282PV62}"
export COSYVOICE3_REFERENCE_WAV="${COSYVOICE3_REFERENCE_WAV:-/Volumes/WD/Codes/dub/dub_ios/ios/ExpressionHeadToHead/GeneratedAssets/leijun-1.wav}"
export COSYVOICE3_REFERENCE_TRANSCRIPT="${COSYVOICE3_REFERENCE_TRANSCRIPT:-/Volumes/WD/Codes/dub/dub_ios/ios/ExpressionHeadToHead/GeneratedAssets/leijun-1.txt}"
main(){
    command -v git || return $?; command -v python3 || return $?
    [ "$(git -C "$REPO" branch --show-current)" = "$BRANCH" ] || { printf '[COSYVOICE3-PRELICENSE] ERROR wrong branch\n'; return 2; }
    [ -z "$(git -C "$REPO" status --porcelain)" ] || { printf '[COSYVOICE3-PRELICENSE] ERROR initial worktree must be clean\n'; git -C "$REPO" status --short; return 2; }
    git -C "$REPO" pull --ff-only origin "$BRANCH" || return $?
    printf '[COSYVOICE3-PRELICENSE] STEP 1/5 physical independent clean-room\n'
    bash "$ROOT/validation/run_production_clean_room.sh" || return $?
    printf '[COSYVOICE3-PRELICENSE] STEP 2/5 freeze and commit non-license Production evidence\n'
    bash "$ROOT/validation/finalize_production_nonlicense.sh" || return $?
    printf '[COSYVOICE3-PRELICENSE] STEP 3/5 fresh public-history snapshot\n'
    case "$SNAPSHOT" in "$ROOT/.work/"*) rm -rf "$SNAPSHOT";; esac
    bash "$REPO/tools/create_public_snapshot.sh" "$SNAPSHOT" || return $?
    printf '[COSYVOICE3-PRELICENSE] STEP 4/5 exact public identity/tree review\n'
    python3 "$ROOT/validation/record_public_identity_review.py" --snapshot "$SNAPSHOT" || return $?
    printf '[COSYVOICE3-PRELICENSE] STEP 5/5 exact asset license inventory (PENDING human review)\n'
    python3 "$ROOT/validation/generate_license_review_inventory.py" --asset-root "$ROOT/.work/production-clean-room/fetched-runtime" || return $?
    python3 - "$ROOT/VALIDATION.md" "$ROOT/validation/evidence/public_identity_review.json" "$ROOT/validation/evidence/license_review_inventory.json" <<'PY' || return $?
import json,sys
from pathlib import Path
v=Path(sys.argv[1]); ident=json.loads(Path(sys.argv[2]).read_text()); inv=json.loads(Path(sys.argv[3]).read_text()); text=v.read_text()
if ident.get("status")!="PASS_PUBLIC_IDENTITY_REVIEW": raise SystemExit("public identity review not PASS")
if inv.get("status")!="PENDING_HUMAN_LICENSE_REVIEW": raise SystemExit("license inventory state mismatch")
text=text.replace("PRODUCTION BLOCKER: public release identity review/fresh public snapshot has not run.","PASS FOR PRODUCTION EVIDENCE: fresh one-commit public snapshot identity/tree review passed for the current public snapshot scope.")
if "LICENSE REVIEW INVENTORY READY" not in text: text += "\nLICENSE REVIEW INVENTORY READY / PENDING HUMAN DECISION: exact Candidate asset payload inventory is committed; this is not license approval.\n"
v.write_text(text)
PY
    git -C "$REPO" diff --check || return $?
    git -C "$REPO" add ios/VALIDATION.md ios/validation/evidence/public_identity_review.json ios/validation/evidence/license_review_inventory.json || return $?
    git -C "$REPO" -c user.name="actacomes" -c user.email="developer@actacomes.com" commit -m "release(ios): record pre-license public identity evidence" || return $?
    git -C "$REPO" push origin "$BRANCH" || return $?
    printf '[COSYVOICE3-PRELICENSE] PASS_PRELICENSE head=%s snapshot=%s pending=licenseReview,publicAssetPublication publicRedistributionApproved=false\n' "$(git -C "$REPO" rev-parse HEAD)" "$SNAPSHOT"
}
main "$@"; RC=$?; printf '[COSYVOICE3-PRELICENSE] rc=%s\n' "$RC"; test "$RC" -eq 0
# Code purpose: one-command closure of all automatable Production gates before human license approval and public asset publication.
# Upstream source: Production clean-room/reproducibility/identity/license-inventory tools in this release tree.
# Runtime environment: macOS/Xcode, authenticated actacomes Hugging Face, connected trusted iPhone, Git push access.
# Generated time: 2026-10-03 America/New_York.
# Changes: new orchestrator only; cannot create PASS_LICENSE_REVIEW, cannot make Hugging Face public, cannot set releaseStatus=production.
