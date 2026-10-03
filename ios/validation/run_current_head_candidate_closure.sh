#@title run_current_head_candidate_closure.sh
# Requirement: run the complete current-source CosyVoice3 iOS Candidate closure from the frozen SDK release branch using the connected physical iPhone, immutable private RC and existing release gates.
#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; REPO="$(cd "$ROOT/.." && pwd)"; EXPECTED_BRANCH="release/ios-fixed225-sdk-ready"
export DEVICE_ID="${DEVICE_ID:-00008150-000A05CA1440401C}"; export DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-H5R282PV62}"
export COSYVOICE3_REFERENCE_WAV="${COSYVOICE3_REFERENCE_WAV:-/Volumes/WD/Codes/dub/dub_ios/ios/ExpressionHeadToHead/GeneratedAssets/leijun-1.wav}"
export COSYVOICE3_REFERENCE_TRANSCRIPT="${COSYVOICE3_REFERENCE_TRANSCRIPT:-/Volumes/WD/Codes/dub/dub_ios/ios/ExpressionHeadToHead/GeneratedAssets/leijun-1.txt}"
main(){
    command -v git || return $?; command -v python3 || return $?; command -v swift || return $?; command -v xcodebuild || return $?; command -v xcrun || return $?
    local branch status head
    branch="$(git -C "$REPO" branch --show-current)" || return $?
    [ "$branch" = "$EXPECTED_BRANCH" ] || { printf '[COSYVOICE3-CANDIDATE-CLOSURE] ERROR expected branch=%s observed=%s\n' "$EXPECTED_BRANCH" "$branch"; return 2; }
    status="$(git -C "$REPO" status --porcelain --untracked-files=no)" || return $?
    [ -z "$status" ] || { printf '[COSYVOICE3-CANDIDATE-CLOSURE] ERROR tracked worktree must be clean:\n%s\n' "$status"; return 2; }
    [ -f "$COSYVOICE3_REFERENCE_WAV" ] || { printf '[COSYVOICE3-CANDIDATE-CLOSURE] ERROR reference WAV missing: %s\n' "$COSYVOICE3_REFERENCE_WAV"; return 2; }
    [ -s "$COSYVOICE3_REFERENCE_TRANSCRIPT" ] || { printf '[COSYVOICE3-CANDIDATE-CLOSURE] ERROR reference transcript missing/empty: %s\n' "$COSYVOICE3_REFERENCE_TRANSCRIPT"; return 2; }
    git -C "$REPO" fetch origin "$EXPECTED_BRANCH" || return $?
    git -C "$REPO" pull --ff-only origin "$EXPECTED_BRANCH" || return $?
    head="$(git -C "$REPO" rev-parse HEAD)" || return $?
    printf '[COSYVOICE3-CANDIDATE-CLOSURE] source=%s device=%s team=%s\n' "$head" "$DEVICE_ID" "$DEVELOPMENT_TEAM"
    printf '[COSYVOICE3-CANDIDATE-CLOSURE] referenceWav=%s\n' "$COSYVOICE3_REFERENCE_WAV"
    printf '[COSYVOICE3-CANDIDATE-CLOSURE] referenceTranscript=%s\n' "$COSYVOICE3_REFERENCE_TRANSCRIPT"
    bash "$ROOT/validation/finalize_ios_fixed225_candidate_nonlicense.sh" || return $?
    printf '[COSYVOICE3-CANDIDATE-CLOSURE] PASS finalHead=%s\n' "$(git -C "$REPO" rev-parse HEAD)"
}
main "$@"; RC=$?; printf '[COSYVOICE3-CANDIDATE-CLOSURE] rc=%s\n' "$RC"; test "$RC" -eq 0
# Code purpose: single local entry point for the current-source Candidate closure: Swift build -> pinned full-runtime rebuild -> physical flowSteps=6 cold/warm public-API benchmark -> release receipt -> Candidate metadata/audit -> actacomes commit/push.
# Upstream code: ios/validation/finalize_ios_fixed225_candidate_nonlicense.sh and its existing rebuild/benchmark/receipt helpers.
# Purpose: avoid manually running or reordering Candidate gates while preserving every intermediate diagnostic printed by the existing tools.
# Runtime environment: Apple Silicon macOS, Xcode, Python 3.11, authenticated actacomes Hugging Face, connected trusted iPhone, Git push access.
# Generated time: 2026-10-03 America/New_York.
# Changes: new wrapper only; no model/runtime behavior changes. Defaults use the already validated physical iPhone/signing team/reference fixture and remain overrideable through environment variables.
