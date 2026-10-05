#@title run_dynamic_production_nonlicense_closure.sh
# Requirement: complete every automatable dynamic Production gate except license/public-asset publication: independent physical clean-room, release-tree reproducibility, fresh public snapshot, and full public-identity review. Never approve licensing, public redistribution or make model assets public.
#!/usr/bin/env bash
set -u -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
BRANCH="${COSYVOICE3_DYNAMIC_CANDIDATE_BRANCH:-release/ios-dynamic-n1-sdk-ready}"
SNAPSHOT="${COSYVOICE3_PUBLIC_SNAPSHOT_DIR:-$ROOT/.work/public-snapshot/Cosyvoice-dynamic-public}"
MILESTONE="$ROOT/validation/ios_dynamic_production_nonlicense_ready.json"

fail(){ printf '[COSYVOICE3-DYNAMIC-PRODUCTION-NONLICENSE] ERROR %s\n' "$1"; return 1; }

main(){
    command -v git || return $?
    command -v python3 || return $?
    command -v xcodebuild || return $?
    command -v xcrun || return $?
    [ -n "${DEVICE_ID:-}" ] || { fail "set DEVICE_ID"; return 2; }
    [ -n "${DEVELOPMENT_TEAM:-}" ] || { fail "set DEVELOPMENT_TEAM"; return 2; }
    [ -f "${COSYVOICE3_REFERENCE_WAV:-}" ] || { fail "set COSYVOICE3_REFERENCE_WAV"; return 2; }
    [ -s "${COSYVOICE3_REFERENCE_TRANSCRIPT:-}" ] || { fail "set COSYVOICE3_REFERENCE_TRANSCRIPT"; return 2; }
    [ "$(git -C "$REPO" branch --show-current)" = "$BRANCH" ] || { fail "expected $BRANCH"; return 2; }
    [ -z "$(git -C "$REPO" status --porcelain)" ] || { git -C "$REPO" status --short; fail "worktree must be clean"; return 2; }
    git -C "$REPO" pull --ff-only origin "$BRANCH" || return $?

    python3 - "$ROOT/validation/release_receipt.json" <<'PY' || return $?
import json,sys
r=json.load(open(sys.argv[1]))
if r.get("releaseStatus")!="candidate" or r.get("profile")!="ios18-dynamic-n1-n479" or r.get("technicalDistributionReady") is not True: raise SystemExit("canonical dynamic Candidate receipt missing")
if r.get("publicRedistributionApproved") is not False: raise SystemExit("unexpected redistribution approval before license gate")
print("[COSYVOICE3-DYNAMIC-PRODUCTION-NONLICENSE] CANDIDATE_AUTHORITY_PASS "+r["assetIdentity"],flush=True)
PY

    printf '[COSYVOICE3-DYNAMIC-PRODUCTION-NONLICENSE] STEP 1/4 independent physical clean-room\n'
    COSYVOICE3_RELEASE_BRANCH="$BRANCH" bash "$ROOT/validation/run_production_clean_room.sh" || return $?

    printf '[COSYVOICE3-DYNAMIC-PRODUCTION-NONLICENSE] STEP 2/4 freeze clean-room + deterministic release-tree evidence\n'
    COSYVOICE3_RELEASE_BRANCH="$BRANCH" bash "$ROOT/validation/finalize_production_nonlicense.sh" || return $?

    printf '[COSYVOICE3-DYNAMIC-PRODUCTION-NONLICENSE] STEP 3/4 fresh one-commit public snapshot\n'
    [ "$(git -C "$REPO" branch --show-current)" = "$BRANCH" ] || return 2
    [ -z "$(git -C "$REPO" status --porcelain)" ] || { git -C "$REPO" status --short; fail "worktree dirty after nonlicense finalization"; return 2; }
    case "$SNAPSHOT" in "$ROOT/.work/"*) rm -rf "$SNAPSHOT";; *) [ ! -e "$SNAPSHOT" ] || { fail "non-tool-owned snapshot destination already exists: $SNAPSHOT"; return 2; };; esac
    bash "$REPO/tools/create_public_snapshot.sh" "$SNAPSHOT" || return $?

    printf '[COSYVOICE3-DYNAMIC-PRODUCTION-NONLICENSE] STEP 4/4 exact identity/tree review; license deliberately skipped\n'
    python3 "$ROOT/validation/record_public_identity_review.py" --snapshot "$SNAPSHOT" || return $?
    python3 - "$ROOT/VALIDATION.md" "$ROOT/validation/evidence/public_identity_review.json" "$ROOT/validation/release_receipt.json" "$MILESTONE" <<'PY' || return $?
import json,sys,time
from pathlib import Path
v=Path(sys.argv[1]);identity=json.loads(Path(sys.argv[2]).read_text());release=json.loads(Path(sys.argv[3]).read_text());text=v.read_text()
if identity.get("status")!="PASS_PUBLIC_IDENTITY_REVIEW": raise SystemExit("public identity review is not PASS")
if release.get("profile")!="ios18-dynamic-n1-n479": raise SystemExit("canonical Candidate is not dynamic N1")
text=text.replace("PRODUCTION BLOCKER: public release identity review/fresh public snapshot has not run.","PASS FOR PRODUCTION EVIDENCE: fresh one-commit public snapshot identity/tree review passed for the current dynamic Candidate scope.")
if "DYNAMIC NON-LICENSE PRODUCTION GATES PASS" not in text:
    text += "\nDYNAMIC NON-LICENSE PRODUCTION GATES PASS: independent physical clean-room, release-tree reproducibility and fresh public identity/tree review are committed. Remaining: human license/redistribution approval and, only after that approval, immutable public runtime-asset publication.\n"
v.write_text(text)
m={
 "schemaVersion":1,"status":"PASS_ALL_AUTOMATABLE_PRODUCTION_GATES_EXCEPT_LICENSE_AND_PUBLIC_ASSET",
 "profile":release["profile"],"assetIdentity":release["assetIdentity"],"releaseStatus":"candidate",
 "cleanRoomIntegration":"PASS","releaseTreeReproducible":"PASS","publicIdentityReview":"PASS",
 "licenseReview":"PENDING_HUMAN","publicAssetPublication":"BLOCKED_BY_LICENSE",
 "publicRedistributionApproved":False,"recordedAtUnix":int(time.time())
}
Path(sys.argv[4]).write_text(json.dumps(m,indent=2,sort_keys=True)+"\n")
print("[COSYVOICE3-DYNAMIC-PRODUCTION-NONLICENSE] EVIDENCE_PASS "+json.dumps(m,sort_keys=True),flush=True)
PY
    git -C "$REPO" diff --check || return $?
    git -C "$REPO" add ios/VALIDATION.md ios/validation/evidence/public_identity_review.json ios/validation/ios_dynamic_production_nonlicense_ready.json || return $?
    git -C "$REPO" -c user.name="actacomes" -c user.email="developer@actacomes.com" commit -m "release(ios): record dynamic nonlicense Production gates" || return $?
    git -C "$REPO" push origin "$BRANCH" || return $?
    printf '[COSYVOICE3-DYNAMIC-PRODUCTION-NONLICENSE] PASS head=%s snapshot=%s pending=licenseReview,publicAssetPublication public=false\n' "$(git -C "$REPO" rev-parse HEAD)" "$SNAPSHOT"
}
main "$@"
RC=$?
printf '[COSYVOICE3-DYNAMIC-PRODUCTION-NONLICENSE] rc=%s\n' "$RC"
test "$RC" -eq 0

# Code purpose: one-command closure of every automatable dynamic iOS Production gate except human license approval and consequent public asset publication.
# Upstream source: canonical dynamic Candidate receipt/baseline, profile-generic physical ProductionCleanRoom, deterministic release-tree, fresh snapshot and expanded identity gate.
# Runtime environment: dynamic Candidate release branch on canonical macOS Apple-Silicon host, connected physical iPhone, private HF access.
# Generated time: 2026-10-04 America/New_York.
# Changes: new dynamic non-license Production closure; explicitly skips license inventory/decision and never changes asset visibility.
