#@title finalize_ios_fixed225_candidate_nonlicense.sh
# Requirement: run every non-Production Candidate gate in order and update/push release metadata only after all build/rebuild/device/benchmark/evidence checks pass.
#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
EXPECTED_BRANCH="release/ios-fixed225-sdk-ready"
BUILD_RECEIPT="$ROOT/validation/evidence/standalone_build.json"
MILESTONE_REF="milestone/ios-fixed225-distribution-ready-2026-10-02"
main(){
    command -v git || return $?; command -v python3 || return $?; command -v swift || return $?; command -v xcodebuild || return $?
    local branch status head xcode
    branch="$(git -C "$REPO" branch --show-current)" || return $?
    [ "$branch" = "$EXPECTED_BRANCH" ] || { printf '[COSYVOICE3-CANDIDATE] ERROR expected branch=%s observed=%s\n' "$EXPECTED_BRANCH" "$branch"; return 2; }
    status="$(git -C "$REPO" status --porcelain --untracked-files=no)" || return $?
    if [ -n "$status" ]; then printf '[COSYVOICE3-CANDIDATE] ERROR tracked worktree is not clean before finalizer:\n%s\n' "$status"; return 2; fi
    git -C "$REPO" pull --ff-only origin "$EXPECTED_BRANCH" || return $?
    head="$(git -C "$REPO" rev-parse HEAD)" || return $?
    printf '[COSYVOICE3-CANDIDATE] source=%s\n' "$head"
    printf '[COSYVOICE3-CANDIDATE] STEP 1/6 standalone Swift package build\n'
    swift test --package-path "$ROOT" || return $?
    xcode="$(xcodebuild -version | tr '\n' ';')" || return $?
    mkdir -p "$(dirname "$BUILD_RECEIPT")" || return $?
    python3 - "$BUILD_RECEIPT" "$head" "$xcode" <<'PY'
import json,sys,time
from pathlib import Path
path,head,xcode=sys.argv[1:]
receipt={"schemaVersion":1,"status":"PASS","engine":"CosyVoice3","platform":"iOS","gate":"standaloneBuild","sourceCommit":head,"command":"swift test --package-path ios","xcode":xcode.rstrip(";"),"recordedAtUnix":int(time.time())}
Path(path).write_text(json.dumps(receipt,indent=2,sort_keys=True)+"\n")
print("[COSYVOICE3-CANDIDATE] BUILD_PASS "+json.dumps(receipt,sort_keys=True),flush=True)
PY
    [ $? -eq 0 ] || return $?
    printf '[COSYVOICE3-CANDIDATE] STEP 2/6 pinned supported full-runtime rebuild\n'
    COSYVOICE3_REBUILD_RECEIPT="$ROOT/validation/evidence/full_runtime_rebuild.json" bash "$ROOT/rebuild_assets.sh" --profile ios-fixed225-reference || return $?
    printf '[COSYVOICE3-CANDIDATE] STEP 3/6 immutable private-RC physical cold/warm public-API benchmark\n'
    bash "$ROOT/validation/run_candidate_benchmark.sh" || return $?
    printf '[COSYVOICE3-CANDIDATE] STEP 4/6 generate Candidate release receipt\n'
    python3 "$ROOT/validation/generate_candidate_release_receipt.py" || return $?
    printf '[COSYVOICE3-CANDIDATE] STEP 5/6 atomically transition metadata to Technical Distribution-Ready Candidate\n'
    python3 "$ROOT/validation/finalize_candidate_metadata.py" || return $?
    printf '[COSYVOICE3-CANDIDATE] STEP 6/6 strict Candidate consistency audit and push\n'
    python3 "$ROOT/validation/audit_candidate_state.py" || return $?
    git -C "$REPO" diff --check || return $?
    printf '[COSYVOICE3-CANDIDATE] pending release changes:\n'
    git -C "$REPO" status --short
    git -C "$REPO" add ios/manifest.json ios/assets/releases.json ios/RELEASE_CHECKLIST.md ios/BENCHMARK.md ios/README.md ios/SDK_RELEASE.md ios/API.md ios/ASSETS.md ios/validation/evidence/standalone_build.json ios/validation/evidence/full_runtime_rebuild.json ios/validation/evidence/candidate_benchmark.json ios/validation/release_receipt.json ios/validation/ios_fixed225_distribution_ready_2026-10-02.json ios/MILESTONES/IOS_FIXED225_DISTRIBUTION_READY_2026-10-02.md || return $?
    git -C "$REPO" ls-files --error-unmatch ios/validation/evidence/standalone_build.json >/dev/null || { printf '[COSYVOICE3-CANDIDATE] ERROR standalone_build.json was not staged/tracked\n'; return 4; }
    git -C "$REPO" ls-files --error-unmatch ios/validation/evidence/full_runtime_rebuild.json >/dev/null || { printf '[COSYVOICE3-CANDIDATE] ERROR full_runtime_rebuild.json was not staged/tracked\n'; return 4; }
    git -C "$REPO" ls-files --error-unmatch ios/validation/evidence/candidate_benchmark.json >/dev/null || { printf '[COSYVOICE3-CANDIDATE] ERROR candidate_benchmark.json was not staged/tracked\n'; return 4; }
    local unstaged
    unstaged="$(git -C "$REPO" diff --name-only)" || return $?
    if [ -n "$unstaged" ]; then printf '[COSYVOICE3-CANDIDATE] ERROR unstaged tracked changes remain before release commit:\n%s\n' "$unstaged"; return 3; fi
    git -C "$REPO" -c user.name="actacomes" -c user.email="developer@actacomes.com" commit -m "release(ios): mark fixed225 technical distribution ready" || return $?
    printf '[COSYVOICE3-CANDIDATE] post-commit source-binding audit before push\n'
    python3 "$ROOT/validation/audit_candidate_state.py" || return $?
    git -C "$REPO" push origin "$EXPECTED_BRANCH" || return $?
    git -C "$REPO" push origin "HEAD:refs/heads/$MILESTONE_REF" || return $?
    printf '[COSYVOICE3-CANDIDATE] COMPLETE status=CANDIDATE technicalDistributionReady=true publicRedistributionApproved=false head=%s milestone=%s\n' "$(git -C "$REPO" rev-parse HEAD)" "$MILESTONE_REF"
}
main "$@"
RC=$?
printf '[COSYVOICE3-CANDIDATE] rc=%s\n' "$RC"
test "$RC" -eq 0
# Code purpose: ZipVoice-style one-command non-license Candidate finalizer for CosyVoice3 iOS; state transition and push occur only after all three outstanding Candidate gates pass.
# Upstream: current release branch, rebuild_assets.sh, immutable HF private RC, DeviceSmoke candidate benchmark, Candidate release receipt/metadata/audit helpers.
# Runtime: Apple Silicon macOS/Xcode, Python 3.11, authenticated actacomes Hugging Face, connected physical iPhone, Git push access.
# Generated: 2026-10-02 America/New_York.
# Changes: new file; current-HEAD Swift build, full runtime rebuild, physical cold/warm benchmark, release receipt, atomic Candidate metadata transition, strict audit, actacomes commit/push and frozen distribution-ready milestone ref.\n# Changes 2026-10-02: stage API/ASSETS transition docs and reject any remaining unstaged tracked diff before the release commit.
# Changes 2026-10-02: fail closed unless all three Candidate evidence JSON files are actually tracked after staging, preventing ignored build-named receipts from producing a locally-valid but incomplete release commit.

# Changes 2026-10-03: run the strict Candidate audit again after creating the release commit and before any push; the audit binds evidence to the direct source parent and permits only the fixed release metadata/evidence path set in that child commit.
