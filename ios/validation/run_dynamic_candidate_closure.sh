#@title run_dynamic_candidate_closure.sh
# Requirement: close every automatable technical Candidate gate for the already registered dynamic N1 private RC: current-source build/isolation, local runtime reconstruction vs immutable RC, physical cold/warm public-API benchmark, canonical Mac environment, N0 policy, Candidate receipt and canonical metadata promotion. License is not evaluated or approved here.
#!/usr/bin/env bash
set -u -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
BRANCH="${COSYVOICE3_DYNAMIC_RELEASE_BRANCH:-experiment/ios-dynamic-acoustic}"
CANDIDATE_BRANCH="${COSYVOICE3_DYNAMIC_CANDIDATE_BRANCH:-release/ios-dynamic-n1-sdk-ready}"
PROFILE="${COSYVOICE3_ASSET_PROFILE:-ios-dynamic-n1-n479-reference}"
VERSION="${COSYVOICE3_ASSET_VERSION:-0.2.0-rc1}"
WORK="$ROOT/.work/dynamic-candidate-closure"
IMMUTABLE="$WORK/immutable-runtime"
REBUILT_WORK="$WORK/rebuilt-integration"
BENCH="$ROOT/validation/evidence/dynamic_candidate_benchmark.json"
ENV_RECEIPT="$ROOT/validation/evidence/dynamic_release_environment.json"
PYTHON="$ROOT/.venv-release/bin/python"

fail(){ printf '[COSYVOICE3-DYNAMIC-CANDIDATE] ERROR %s\n' "$1"; return 1; }

main(){
    command -v git || return $?
    command -v python3 || return $?
    command -v swift || return $?
    command -v xcodebuild || return $?
    command -v xcrun || return $?
    [ -n "${DEVICE_ID:-}" ] || { fail "set DEVICE_ID"; return 2; }
    [ -n "${DEVELOPMENT_TEAM:-}" ] || { fail "set DEVELOPMENT_TEAM"; return 2; }
    [ -f "${COSYVOICE3_REFERENCE_WAV:-}" ] || { fail "set COSYVOICE3_REFERENCE_WAV"; return 2; }
    [ -s "${COSYVOICE3_REFERENCE_TRANSCRIPT:-}" ] || { fail "set COSYVOICE3_REFERENCE_TRANSCRIPT"; return 2; }
    [ "$(git -C "$REPO" branch --show-current)" = "$BRANCH" ] || { fail "wrong branch"; return 2; }
    [ -z "$(git -C "$REPO" status --porcelain --untracked-files=no)" ] || { git -C "$REPO" status --short; fail "tracked worktree must be clean"; return 2; }
    git -C "$REPO" pull --ff-only origin "$BRANCH" || return $?
    if [ ! -x "$PYTHON" ]; then python3 -m venv "$ROOT/.venv-release" || return $?; fi
    "$PYTHON" -m pip install -r "$ROOT/requirements-release.txt" || return $?

    "$PYTHON" - "$ROOT/assets/releases.json" "$PROFILE" "$VERSION" <<'PY' || return $?
import json,sys
c=json.load(open(sys.argv[1]));rows=[r for r in c.get("releases",[]) if r.get("profile")==sys.argv[2] and r.get("version")==sys.argv[3]]
if len(rows)!=1: raise SystemExit("dynamic private RC catalog row missing; run finish_ios_dynamic_n1_private_rc.sh first")
r=rows[0]
if r.get("distributionStatus")!="PRIVATE_RC" or r.get("publicRedistributionApproved") is not False: raise SystemExit("dynamic catalog row is not private RC")
print("[COSYVOICE3-DYNAMIC-CANDIDATE] PRIVATE_RC_FOUND revision="+str(r.get("revision")),flush=True)
PY

    rm -rf "$WORK"; mkdir -p "$WORK"

    printf '[COSYVOICE3-DYNAMIC-CANDIDATE] STEP 1/7 current-source standalone build/isolation\n'
    "$PYTHON" "$ROOT/validation/record_dynamic_standalone_build.py" || return $?

    printf '[COSYVOICE3-DYNAMIC-CANDIDATE] STEP 2/7 ordinary-fetch immutable RC and reconstruct local integration runtime\n'
    "$PYTHON" "$ROOT/assets/fetch_assets.py" --profile "$PROFILE" --version "$VERSION" --output "$IMMUTABLE" --force || return $?
    COSYVOICE3_N1_INTEGRATION_WORK="$REBUILT_WORK" bash "$ROOT/experiments/dynamic-acoustic/build_n1_dynamic_candidate.sh" || return $?
    "$PYTHON" "$ROOT/validation/record_dynamic_runtime_rebuild.py" --rebuilt-runtime "$REBUILT_WORK/runtime" --immutable-runtime "$IMMUTABLE" || return $?

    printf '[COSYVOICE3-DYNAMIC-CANDIDATE] STEP 3/7 physical cold/warm public-API benchmark\n'
    COSYVOICE3_ASSET_PROFILE="$PROFILE" COSYVOICE3_ASSET_VERSION="$VERSION" \
    COSYVOICE3_CANDIDATE_BENCHMARK_OUTPUT="$BENCH" \
    bash "$ROOT/validation/run_candidate_benchmark.sh" || return $?

    printf '[COSYVOICE3-DYNAMIC-CANDIDATE] STEP 4/7 canonical release environment\n'
    "$PYTHON" "$ROOT/validation/record_release_environment.py" \
        --device-receipt "$BENCH" --asset-profile "$PROFILE" --asset-version "$VERSION" --output "$ENV_RECEIPT" || return $?

    printf '[COSYVOICE3-DYNAMIC-CANDIDATE] STEP 5/7 N0 fail-closed release policy\n'
    "$PYTHON" "$ROOT/validation/record_dynamic_n0_policy.py" || return $?

    printf '[COSYVOICE3-DYNAMIC-CANDIDATE] STEP 6/7 generate checklist-complete dynamic Candidate receipt\n'
    "$PYTHON" "$ROOT/validation/generate_dynamic_candidate_release_receipt.py" || return $?

    printf '[COSYVOICE3-DYNAMIC-CANDIDATE] STEP 7/7 promote canonical Candidate metadata\n'
    "$PYTHON" "$ROOT/validation/promote_dynamic_candidate_metadata.py" || return $?

    git -C "$REPO" diff --check || return $?
    git -C "$REPO" add \
        ios/assets/releases.json ios/manifest.json ios/validation/release_receipt.json \
        ios/validation/dynamic_release_receipt.json \
        ios/validation/evidence/dynamic_standalone_build.json \
        ios/validation/evidence/dynamic_runtime_rebuild.json \
        ios/validation/evidence/dynamic_candidate_benchmark.json \
        ios/validation/evidence/dynamic_release_environment.json \
        ios/validation/evidence/dynamic_n0_policy.json \
        ios/ASSETS.md ios/README.md ios/API.md ios/BENCHMARK.md ios/VALIDATION.md || return $?
    git -C "$REPO" -c user.name="actacomes" -c user.email="developer@actacomes.com" \
        commit -m "release(ios): promote dynamic N1 private Candidate" || return $?
    local candidate_head
    candidate_head="$(git -C "$REPO" rev-parse HEAD)" || return $?
    "$PYTHON" "$ROOT/validation/record_dynamic_production_baseline.py" --candidate-release-head "$candidate_head" || return $?
    git -C "$REPO" add ios/validation/production_baseline.json || return $?
    git -C "$REPO" -c user.name="actacomes" -c user.email="developer@actacomes.com" \
        commit -m "release(ios): freeze dynamic Candidate baseline" || return $?
    git -C "$REPO" push origin "$BRANCH" || return $?
    git -C "$REPO" push origin "HEAD:refs/heads/$CANDIDATE_BRANCH" || return $?
    printf '[COSYVOICE3-DYNAMIC-CANDIDATE] PASS candidateHead=%s evidenceHead=%s candidateBranch=%s profile=%s/%s license=PENDING public=false\n' "$candidate_head" "$(git -C "$REPO" rev-parse HEAD)" "$CANDIDATE_BRANCH" "$PROFILE" "$VERSION"
}
main "$@"
RC=$?
printf '[COSYVOICE3-DYNAMIC-CANDIDATE] rc=%s\n' "$RC"
test "$RC" -eq 0

# Code purpose: one-command non-license technical Candidate closure for CosyVoice3 dynamic N1...479 after immutable private RC registration.
# Upstream source: immutable dynamic asset catalog, build/rebuild/benchmark/environment/N0 tools and Candidate metadata promotion.
# Runtime environment: canonical Mac Apple-Silicon host, authenticated private HF access, connected trusted physical iPhone.
# Generated time: 2026-10-04 America/New_York.
# Changes: new dynamic Candidate closure; leaves clean-room/reproducibility/license/public identity/public asset publication as Production gates.

# Changes 2026-10-04: after the Candidate authority commit, freeze that exact commit into production_baseline.json in a second evidence-only commit so later Production gates reject runtime-source drift without circular Candidate-head metadata.

# Changes 2026-10-04: successful technical Candidate closure also creates/fast-forwards release/ios-dynamic-n1-sdk-ready, providing a stable ref for the all-SDK matrix; the matrix itself is not switched before this branch actually exists.
