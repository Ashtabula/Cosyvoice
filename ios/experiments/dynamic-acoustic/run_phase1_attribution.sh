#@title run_phase1_attribution.sh
# Requirement: reproduce Phase1 numerical attribution without touching frozen release assets: fresh symbolic conditions -> six-route shard0 matrix -> N225 hybrid downstream -> fail-closed gate refresh.
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
EXP="$ROOT/ios/experiments/dynamic-acoustic"
WORK="${COSYVOICE3_ATTRIBUTION_WORK:-$ROOT/ios/.work/dynamic-acoustic/phase1-attribution-v1}"
PYTHON="${COSYVOICE3_DYNAMIC_PYTHON:-$ROOT/ios/.work/dynamic-acoustic/venv/bin/python}"
SOURCE="${COSYVOICE3_DYNAMIC_SOURCE:-$ROOT/ios/.work/rebuild/ios-fixed225-reference/source}"
MODEL="${COSYVOICE3_DYNAMIC_MODEL:-$ROOT/ios/.work/rebuild/ios-fixed225-reference/model-cache/Fun-CosyVoice3-0.5B-2512}"
FIXTURE="${COSYVOICE3_DYNAMIC_FIXTURE:-$ROOT/ios/.work/rebuild/ios-fixed225-reference/fixture}"
BRANCH="experiment/ios-dynamic-acoustic"

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

    [ -x "$PYTHON" ] || {
        printf '[COSYVOICE3-DYNAMIC-ATTRIBUTION] ERROR missing Python: %s\n' "$PYTHON"
        return 2
    }

    [ "$(git -C "$ROOT" branch --show-current)" = "$BRANCH" ] || {
        printf '[COSYVOICE3-DYNAMIC-ATTRIBUTION] ERROR wrong branch\n'
        return 2
    }

    [ -z "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ] || {
        printf '[COSYVOICE3-DYNAMIC-ATTRIBUTION] ERROR tracked worktree must be clean\n'
        git -C "$ROOT" status --short
        return 2
    }

    [ ! -e "$WORK" ] || {
        printf '[COSYVOICE3-DYNAMIC-ATTRIBUTION] ERROR evidence-preserving work path already exists: %s\n' "$WORK"
        return 2
    }

    local fixed
    fixed="$(find_fixed_asset_root)" || {
        printf '[COSYVOICE3-DYNAMIC-ATTRIBUTION] ERROR set COSYVOICE3_FIXED_ASSET_ROOT to an accepted fixed225 runtime root\n'
        return 2
    }

    printf '[COSYVOICE3-DYNAMIC-ATTRIBUTION] root=%s\n' "$ROOT"
    printf '[COSYVOICE3-DYNAMIC-ATTRIBUTION] head=%s\n' "$(git -C "$ROOT" rev-parse HEAD)"
    printf '[COSYVOICE3-DYNAMIC-ATTRIBUTION] fixedAssetRoot=%s\n' "$fixed"

    mkdir -p "$WORK"

    printf '[COSYVOICE3-DYNAMIC-ATTRIBUTION] STEP 1/4 fresh symbolic conditions\n'
    "$PYTHON" "$EXP/probe_symbolic_conditions.py" \
        --source-root "$SOURCE" \
        --model-dir "$MODEL" \
        --fixture "$FIXTURE" \
        --output "$WORK/conditions"

    printf '[COSYVOICE3-DYNAMIC-ATTRIBUTION] STEP 2/4 six-route N225 shard0 conversion matrix\n'
    "$PYTHON" "$EXP/run_shard0_attribution.py" \
        --source-root "$SOURCE" \
        --model-dir "$MODEL" \
        --fixture "$FIXTURE" \
        --fixed-asset-root "$fixed" \
        --output "$WORK/shard0-attribution"

    printf '[COSYVOICE3-DYNAMIC-ATTRIBUTION] STEP 3/4 N225 downstream hybrid control with frozen shards1-5\n'
    "$PYTHON" "$EXP/run_hybrid_downstream_control.py" \
        --fixed-asset-root "$fixed" \
        --dynamic-conditions-package "$WORK/conditions/conditions.mlpackage" \
        --dynamic-shard0-package "$WORK/shard0-attribution/variants/export_symbolic_fp16/shard0.mlpackage" \
        --conditions-fixture "$WORK/conditions/N225" \
        --shard-fixture "$WORK/shard0-attribution/fixture/N225" \
        --fixture "$FIXTURE" \
        --output "$WORK/hybrid-downstream.json"

    printf '[COSYVOICE3-DYNAMIC-ATTRIBUTION] STEP 4/4 copy compact receipts and refresh Phase1 gate\n'

    cp "$WORK/shard0-attribution/receipt.json" \
        "$EXP/evidence/numerical-attribution-v1.json"

    cp "$WORK/hybrid-downstream.json" \
        "$EXP/evidence/hybrid-downstream-v1.json"

    "$PYTHON" "$EXP/evaluate_phase1_gate.py" \
        --conditions "$EXP/evidence/conditions-host.json" \
        --shard0 "$EXP/evidence/shard0-host.json" \
        --fixed-control "$EXP/evidence/fixed225-control.json" \
        --device-cpu "$EXP/evidence/device-CPU_ONLY.json" \
        --device-ne "$EXP/evidence/device-CPU_AND_NE.json" \
        --attribution "$EXP/evidence/numerical-attribution-v1.json" \
        --hybrid "$EXP/evidence/hybrid-downstream-v1.json" \
        --output "$EXP/evidence/phase1-gate.json" || true

    "$PYTHON" "$EXP/refresh_evidence_index.py" \
        --evidence-dir "$EXP/evidence"

    git -C "$ROOT" diff --check

    printf '[COSYVOICE3-DYNAMIC-ATTRIBUTION] COMPLETE phase2 remains fail-closed pending interpretation\n'
    git -C "$ROOT" status --short
}

main "$@"

# Code purpose: generate apples-to-apples numerical attribution and downstream hybrid evidence before any dynamic shards1-5 work.
# Upstream source: pinned CosyVoice3_NPU Flow source/checkpoint and accepted fixed225 runtime assets.
# Runtime environment: macOS arm64, isolated dynamic Python venv, Core ML Tools 9, Xcode/coremlcompiler.
# Generated time: 2026-10-03 America/New_York.
# Changes: new experiment-only orchestrator; does not modify LLM EOS/cap, shipping runtime, fixed assets, Candidate evidence, or public asset catalog.
