#@title run_phase2_dynamic_flow.sh
# Requirement: run complete six-shard symbolic Flow host validation only after Phase1 proved true dynamic execution and completed numerical attribution; preserve release/Candidate state and commit the resulting experiment evidence.
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
EXP="$ROOT/ios/experiments/dynamic-acoustic"
PYTHON="${COSYVOICE3_DYNAMIC_PYTHON:-$ROOT/ios/.work/dynamic-acoustic/venv/bin/python}"
SOURCE="${COSYVOICE3_DYNAMIC_SOURCE:-$ROOT/ios/.work/rebuild/ios-fixed225-reference/source}"
MODEL="${COSYVOICE3_DYNAMIC_MODEL:-$ROOT/ios/.work/rebuild/ios-fixed225-reference/model-cache/Fun-CosyVoice3-0.5B-2512}"
FIXTURE="${COSYVOICE3_DYNAMIC_FIXTURE:-$ROOT/ios/.work/rebuild/ios-fixed225-reference/fixture}"
WORK="${COSYVOICE3_PHASE2_WORK:-}"
BRANCH="experiment/ios-dynamic-acoustic"
EVIDENCE="$EXP/evidence/phase2-dynamic-flow-host-v1.json"

find_fixed_asset_root(){
    if [ -n "${COSYVOICE3_FIXED_ASSET_ROOT:-}" ]; then
        printf '%s\n' "$COSYVOICE3_FIXED_ASSET_ROOT"
        return 0
    fi
    for candidate in \
        "$ROOT/ios/.work/production-clean-room/fetched-runtime" \
        "$ROOT/ios/.work/rebuilt-runtime/ios-fixed225-reference" \
        "$ROOT/ios/validation/DeviceSmoke/GeneratedAssets/Runtime"
    do
        if [ -f "$candidate/cosyvoice3_fixed225.json" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

main(){
    command -v git
    command -v xcrun

    [ "$(git -C "$ROOT" branch --show-current)" = "$BRANCH" ] || {
        echo "[COSYVOICE3-DYNAMIC-PHASE2] ERROR wrong branch"
        return 2
    }

    [ -x "$PYTHON" ] || {
        echo "[COSYVOICE3-DYNAMIC-PHASE2] ERROR missing dynamic Python: $PYTHON"
        return 2
    }

    [ -z "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ] || {
        echo "[COSYVOICE3-DYNAMIC-PHASE2] ERROR tracked worktree must be clean"
        git -C "$ROOT" status --short
        return 2
    }

    if [ -z "$WORK" ]; then
        local candidate_index
        for candidate_index in $(seq 1 99); do
            local candidate="$ROOT/ios/.work/dynamic-acoustic/phase2-dynamic-flow-v$candidate_index"
            if [ ! -e "$candidate" ]; then
                WORK="$candidate"
                break
            fi
        done
    fi

    [ -n "$WORK" ] || {
        echo "[COSYVOICE3-DYNAMIC-PHASE2] ERROR could not allocate evidence-preserving work directory"
        return 2
    }

    [ ! -e "$WORK" ] || {
        echo "[COSYVOICE3-DYNAMIC-PHASE2] ERROR evidence-preserving work path already exists: $WORK"
        return 2
    }

    local fixed
    fixed="$(find_fixed_asset_root)" || {
        echo "[COSYVOICE3-DYNAMIC-PHASE2] ERROR set COSYVOICE3_FIXED_ASSET_ROOT to an accepted fixed225 runtime root"
        return 2
    }

    "$PYTHON" - <<'PY'
import json
from pathlib import Path
gate = json.loads(Path("ios/experiments/dynamic-acoustic/evidence/phase1-gate.json").read_text())
if gate.get("trueDynamicShapeFeasible") is not True:
    raise SystemExit("Phase2 experiment blocked: trueDynamicShapeFeasible != true")
if gate.get("numericalAttributionComplete") is not True:
    raise SystemExit("Phase2 experiment blocked: numericalAttributionComplete != true")
print("[COSYVOICE3-DYNAMIC-PHASE2] phase1EntryBasis=PASS")
print("[COSYVOICE3-DYNAMIC-PHASE2] releaseNumericalAcceptance=", gate.get("numericalAcceptancePass"))
print("[COSYVOICE3-DYNAMIC-PHASE2] note=experiment continuation only; production promotion remains closed")
PY

    echo "[COSYVOICE3-DYNAMIC-PHASE2] root=$ROOT"
    echo "[COSYVOICE3-DYNAMIC-PHASE2] head=$(git -C "$ROOT" rev-parse HEAD)"
    echo "[COSYVOICE3-DYNAMIC-PHASE2] fixedAssetRoot=$fixed"
    echo "[COSYVOICE3-DYNAMIC-PHASE2] work=$WORK"

    "$PYTHON" "$EXP/run_phase2_dynamic_flow.py" \
        --source-root "$SOURCE" \
        --model-dir "$MODEL" \
        --fixture "$FIXTURE" \
        --fixed-asset-root "$fixed" \
        --precision fp16 \
        --output "$WORK"

    cp "$WORK/receipt.json" "$EVIDENCE"
    "$PYTHON" "$EXP/refresh_evidence_index.py" --evidence-dir "$EXP/evidence"

    echo "===== PHASE 2 SUMMARY ====="
    "$PYTHON" - <<'PY'
import json
from pathlib import Path
r = json.loads(Path("ios/experiments/dynamic-acoustic/evidence/phase2-dynamic-flow-host-v1.json").read_text())
print("status =", r.get("status"))
print("precision =", r.get("precision"))
print("flowSteps =", r.get("flowSteps"))
print("packageCount =", len(r.get("packages") or []))
for row in r.get("tests") or []:
    print()
    print("N =", row.get("N"), "T =", row.get("T"), "G =", row.get("G"))
    first = row.get("firstCallVelocityVsOfficial") or {}
    mel = row.get("sixStepMelVsOfficial") or {}
    print("firstCallVelocityVsOfficial", "maxAbs=", first.get("maxAbsError"), "rmse=", first.get("rmse"), "relativeL2=", first.get("relativeL2"), "cosine=", first.get("cosineSimilarity"))
    print("sixStepMelVsOfficial", "maxAbs=", mel.get("maxAbsError"), "rmse=", mel.get("rmse"), "relativeL2=", mel.get("relativeL2"), "cosine=", mel.get("cosineSimilarity"))
    if row.get("N") == 225:
        frozen = row.get("frozenSixStepMelVsOfficial") or {}
        delta = row.get("dynamicSixStepMelVsFrozen") or {}
        print("frozenSixStepMelVsOfficial", "maxAbs=", frozen.get("maxAbsError"), "rmse=", frozen.get("rmse"), "relativeL2=", frozen.get("relativeL2"), "cosine=", frozen.get("cosineSimilarity"))
        print("dynamicSixStepMelVsFrozen", "maxAbs=", delta.get("maxAbsError"), "rmse=", delta.get("rmse"), "relativeL2=", delta.get("relativeL2"), "cosine=", delta.get("cosineSimilarity"))
print()
print("productionPromotion =", r.get("productionPromotion"))
PY

    git -C "$ROOT" diff --check
    git -C "$ROOT" config user.name "actacomes"
    git -C "$ROOT" config user.email "developer@actacomes.com"
    git -C "$ROOT" add \
        ios/experiments/dynamic-acoustic/evidence/phase2-dynamic-flow-host-v1.json \
        ios/experiments/dynamic-acoustic/evidence/evidence-index.json

    git -C "$ROOT" diff --cached --check
    git -C "$ROOT" diff --cached --stat

    if git -C "$ROOT" diff --cached --quiet; then
        echo "[COSYVOICE3-DYNAMIC-PHASE2] no new evidence to commit"
    else
        git -C "$ROOT" commit -m "experiment(ios): record six-shard dynamic Flow host evidence"
    fi

    git -C "$ROOT" push origin "$BRANCH"

    local local_head remote_head
    local_head="$(git -C "$ROOT" rev-parse HEAD)"
    remote_head="$(git -C "$ROOT" ls-remote origin "refs/heads/$BRANCH" | awk '{print $1}')"
    echo "[COSYVOICE3-DYNAMIC-PHASE2] local=$local_head"
    echo "[COSYVOICE3-DYNAMIC-PHASE2] remote=$remote_head"
    [ "$local_head" = "$remote_head" ] || {
        echo "[COSYVOICE3-DYNAMIC-PHASE2] ERROR remote HEAD mismatch"
        return 2
    }

    echo "[COSYVOICE3-DYNAMIC-PHASE2] COMPLETE"
}

main "$@"

# Code purpose: execute and preserve complete six-shard true-dynamic Flow host evidence for N186/T674 and N225/T752, including natural 6-step rollout and frozen N225 control.
# Upstream source: Ashtabula/Cosyvoice experiment/ios-dynamic-acoustic; CosyVoice3_NPU@878940245562bcd1dd0231d78157ba78d70b39f6; accepted fixed225 runtime assets.
# Runtime environment: macOS arm64, isolated dynamic Python3.11/torch2.7/coremltools9, Xcode coremlcompiler.
# Generated time: 2026-10-03 America/New_York.
# Changes: experiment-only Phase2 runner; production numerical acceptance remains closed and no shipping runtime/HiFT/LLM/Candidate files are modified.
# Changes 2026-10-03: auto-select the first unused phase2-dynamic-flow-vN work directory when COSYVOICE3_PHASE2_WORK is unset, preserving failed receipts instead of requiring manual renaming.
