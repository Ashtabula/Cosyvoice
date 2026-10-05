#@title finalize_production_nonlicense.sh
# Requirement: after physical Production clean-room PASS, freeze deterministic release-tree evidence, record the non-license Production milestone, commit only evidence/status files, audit again, and push without authorizing public redistribution.
#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; REPO="$(cd "$ROOT/.." && pwd)"; BRANCH="${COSYVOICE3_RELEASE_BRANCH:-$(git -C "$REPO" branch --show-current)}"; CLEAN="$ROOT/validation/evidence/production_clean_room.json"; TREE="$ROOT/validation/evidence/release_tree_reproducible.json"; MJSON="$ROOT/validation/ios_production_nonlicense_ready.json"; MMD="$ROOT/MILESTONES/IOS_PRODUCTION_NONLICENSE_READY.md"
main(){
    command -v git || return $?; command -v python3 || return $?
    [ "$(git -C "$REPO" branch --show-current)" = "$BRANCH" ] || { printf '[COSYVOICE3-PRODUCTION-NONLICENSE] ERROR wrong branch\n'; return 2; }
    [ -f "$CLEAN" ] || { printf '[COSYVOICE3-PRODUCTION-NONLICENSE] ERROR clean-room receipt missing\n'; return 2; }
    local unexpected
    unexpected="$(git -C "$REPO" status --porcelain | grep -v '^?? ios/validation/evidence/production_clean_room.json$' || true)"
    [ -z "$unexpected" ] || { printf '[COSYVOICE3-PRODUCTION-NONLICENSE] ERROR unexpected worktree changes:\n%s\n' "$unexpected"; return 2; }
    python3 "$ROOT/validation/record_release_tree_reproducibility.py" --output "$TREE" || return $?
    python3 "$ROOT/validation/check_production_nonlicense.py" || return $?
    python3 - "$ROOT/VALIDATION.md" "$CLEAN" "$TREE" "$MJSON" "$MMD" <<'PY' || return $?
import json,sys,time
from pathlib import Path
v=Path(sys.argv[1]); clean=json.loads(Path(sys.argv[2]).read_text()); tree=json.loads(Path(sys.argv[3]).read_text()); text=v.read_text()
text=text.replace("PRODUCTION BLOCKER: clean-room consumer integration has not run.","PASS FOR PRODUCTION EVIDENCE: independent physical-device clean-room consumer integration passed through the stable public CosyVoice3Core API.")
text=text.replace("PRODUCTION BLOCKER: release-tree reproducibility has not been frozen.","PASS FOR PRODUCTION EVIDENCE: deterministic public snapshot tree/archive reproducibility is frozen and hash-bound.")
v.write_text(text)
release=json.loads((Path(sys.argv[1]).parent/"release_receipt.json").read_text())
m={"schemaVersion":1,"status":"PASS_EXCEPT_LICENSE_IDENTITY_AND_PUBLICATION","releaseStatus":"candidate","profile":release.get("profile"),"assetIdentity":release.get("assetIdentity"),"publicRedistributionApproved":False,"cleanRoomIntegration":clean,"releaseTreeReproducible":tree,"pending":["licenseReview","publicIdentityReview","publicAssetPublication"],"recordedAtUnix":int(time.time())}
Path(sys.argv[4]).write_text(json.dumps(m,indent=2,sort_keys=True)+"\n")
Path(sys.argv[5]).parent.mkdir(parents=True,exist_ok=True); Path(sys.argv[5]).write_text("# CosyVoice3 iOS Production non-license milestone\n\nStatus: **PASS except license review, public identity/fresh snapshot, and public asset publication.**\n\nThe independent public-API physical-device clean-room gate and deterministic public release-tree gate are committed for the canonical Candidate profile. Candidate runtime/source remains the frozen validated baseline; public redistribution remains false.\n\nPending: licenseReview, publicIdentityReview, publicAssetPublication.\n")
PY
    git -C "$REPO" diff --check || return $?
    git -C "$REPO" add ios/VALIDATION.md ios/validation/evidence/production_clean_room.json ios/validation/evidence/release_tree_reproducible.json ios/validation/ios_production_nonlicense_ready.json ios/MILESTONES/IOS_PRODUCTION_NONLICENSE_READY.md || return $?
    git -C "$REPO" -c user.name="actacomes" -c user.email="developer@actacomes.com" commit -m "release(ios): freeze non-license Production evidence" || return $?
    python3 "$ROOT/validation/check_production_nonlicense.py" || return $?
    git -C "$REPO" push origin "$BRANCH" || return $?
    printf '[COSYVOICE3-PRODUCTION-NONLICENSE] PASS head=%s publicRedistributionApproved=false\n' "$(git -C "$REPO" rev-parse HEAD)"
}
main "$@"; RC=$?; printf '[COSYVOICE3-PRODUCTION-NONLICENSE] rc=%s\n' "$RC"; test "$RC" -eq 0
# Code purpose: evidence-only clean-room/reproducibility Production milestone; cannot approve licensing, public identity, public assets or Production status.
# Runtime environment: clean release checkout after run_production_clean_room.sh PASS.
# Generated time: 2026-10-03 America/New_York.

# Changes 2026-10-04: remove fixed225 branch/date authority; operate on the current canonical Candidate/release branch and record generic profile-bound non-license Production evidence.
