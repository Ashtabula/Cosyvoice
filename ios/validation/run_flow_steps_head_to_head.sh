#@title run_flow_steps_head_to_head.sh
# Requirement: run a validation-only physical-iPhone 10/8/6 Flow scheduler head-to-head using one shared LLM token trajectory, one acoustic model set, identical reference conditioning/noise, and immutable promoted RC assets.
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PYTHON="$ROOT/.venv-release/bin/python"
WORK="$ROOT/.work/flow-steps-head-to-head"
DEFAULT_ASSET_ROOT="$ROOT/.work/runtime-performance/fetched-runtime"
ASSET_ROOT="${COSYVOICE3_FLOW_STEPS_ASSET_ROOT:-$DEFAULT_ASSET_ROOT}"
BUNDLE_ID="${COSYVOICE3_FLOW_STEPS_BUNDLE_ID:-com.actacomes.cosyvoice3.candidatebenchmark}"
RECEIPT="$WORK/flow-steps-head-to-head-receipt.json"
EXPECTED_COMMIT="$(git -C "$ROOT/.." rev-parse HEAD)"

main() {
    [ -n "${DEVELOPMENT_TEAM:-}" ] || { printf '[COSYVOICE3-FLOW-H2H] ERROR set DEVELOPMENT_TEAM\n'; return 2; }
    [ -n "${DEVICE_ID:-}" ] || { printf '[COSYVOICE3-FLOW-H2H] ERROR set DEVICE_ID\n'; return 2; }
    [ -n "${COSYVOICE3_REFERENCE_WAV:-}" ] || { printf '[COSYVOICE3-FLOW-H2H] ERROR set COSYVOICE3_REFERENCE_WAV\n'; return 2; }
    [ -n "${COSYVOICE3_REFERENCE_TRANSCRIPT:-}" ] || { printf '[COSYVOICE3-FLOW-H2H] ERROR set COSYVOICE3_REFERENCE_TRANSCRIPT\n'; return 2; }

    command -v python3
    command -v xcrun
    command -v xcodebuild

    if [ ! -x "$PYTHON" ]; then python3 -m venv "$ROOT/.venv-release"; fi
    "$PYTHON" -m pip install -r "$ROOT/requirements-release.txt"

    rm -rf "$WORK"
    mkdir -p "$WORK/audio"

    if [ ! -f "$ASSET_ROOT/asset-manifest.json" ] || [ ! -f "$ASSET_ROOT/cosyvoice3_fixed225.json" ]; then
        ASSET_ROOT="$WORK/fetched-runtime"
        "$PYTHON" "$ROOT/assets/fetch_assets.py" \
            --profile ios-fixed225-reference \
            --version 0.1.0-rc1 \
            --output "$ASSET_ROOT" \
            --force
    fi
    "$PYTHON" "$ROOT/assets/validate_assets.py" --root "$ASSET_ROOT" --require-reference

    printf '[COSYVOICE3-FLOW-H2H] sourceCommit=%s\n' "$EXPECTED_COMMIT"
    printf '[COSYVOICE3-FLOW-H2H] assetRoot=%s\n' "$ASSET_ROOT"

    START_EPOCH="$(date +%s)"

    COSYVOICE3_PROMOTED_RUNTIME_MODE=1 \
    COSYVOICE3_FLOW_STEPS_HEAD_TO_HEAD=1 \
    COSYVOICE3_ASSET_ROOT="$ASSET_ROOT" \
    COSYVOICE3_PYTHON="$PYTHON" \
    CONFIGURATION=Release \
    BUNDLE_ID="$BUNDLE_ID" \
    DERIVED_DATA="$ROOT/.work/FlowStepsHeadToHeadDerivedData" \
    bash "$ROOT/validation/install_device_smoke.sh"

    rm -f "$RECEIPT"
    for attempt in $(seq 1 60); do
        printf '[COSYVOICE3-FLOW-H2H] receipt poll %s/60\n' "$attempt"
        if xcrun devicectl device copy from \
            --device "$DEVICE_ID" \
            --domain-type appDataContainer \
            --domain-identifier "$BUNDLE_ID" \
            --source "Documents/flow-steps-head-to-head-receipt.json" \
            --destination "$RECEIPT"; then
            if [ -s "$RECEIPT" ]; then
                if "$PYTHON" - "$RECEIPT" "$EXPECTED_COMMIT" "$START_EPOCH" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]))
expected=sys.argv[2]
minimum_epoch=int(sys.argv[3])
if int(p.get("recordedAtUnix",0)) < minimum_epoch:
    print(f"[COSYVOICE3-FLOW-H2H] STALE recordedAtUnix={p.get('recordedAtUnix')} minimum={minimum_epoch}",flush=True)
    raise SystemExit(10)
if p.get("sourceCommit")!=expected:
    print(f"[COSYVOICE3-FLOW-H2H] STALE sourceCommit={p.get('sourceCommit')!r} expected={expected}",flush=True)
    raise SystemExit(10)
if p.get("status")!="PASS_FLOW_STEPS_HEAD_TO_HEAD":
    print(f"[COSYVOICE3-FLOW-H2H] FAIL status={p.get('status')} error={p.get('error')}",flush=True)
    raise SystemExit(20)
if p.get("productionDefaultFlowSteps")!=6:
    raise SystemExit(f"receipt productionDefaultFlowSteps={p.get('productionDefaultFlowSteps')!r}, expected 6")
variants={int(v["flowSteps"]):v for v in p.get("variants",[])}
if set(variants)!={6,8,10}:
    raise SystemExit("receipt does not contain exactly 10/8/6 variants")
print("[COSYVOICE3-FLOW-H2H] PASS",json.dumps({
    str(k):{
        "acousticMilliseconds":variants[k]["acousticSynthesisMilliseconds"],
        "acousticRTF":variants[k]["acousticRTF"],
        "steadyComputeMilliseconds":variants[k]["steadyComputeMilliseconds"],
        "steadyComputeRTF":variants[k]["steadyComputeRTF"],
        "wav":variants[k]["wavFilename"],
        "wavSha256":variants[k]["wavSha256"],
    } for k in (10,8,6)
},sort_keys=True),flush=True)
PY
                then
                    break
                else
                    rc=$?
                    if [ "$rc" -eq 10 ]; then
                        rm -f "$RECEIPT"
                        sleep 2
                        continue
                    fi
                    return "$rc"
                fi
            fi
        fi
        sleep 5
        if [ "$attempt" -eq 60 ]; then
            printf '[COSYVOICE3-FLOW-H2H] ERROR receipt not produced\n'
            return 3
        fi
    done

    for steps in 10 8 6; do
        xcrun devicectl device copy from \
            --device "$DEVICE_ID" \
            --domain-type appDataContainer \
            --domain-identifier "$BUNDLE_ID" \
            --source "Documents/flow-steps-$steps.wav" \
            --destination "$WORK/audio/flow-steps-$steps.wav"
    done

    printf '[COSYVOICE3-FLOW-H2H] receipt=%s\n' "$RECEIPT"
    printf '[COSYVOICE3-FLOW-H2H] audio=%s\n' "$WORK/audio"
    "$PYTHON" -m json.tool "$RECEIPT"
}

main "$@"

# Code purpose: build/install the validation-only head-to-head app, wait for exact-source 10/8/6 receipt, and pull all three listening WAVs without modifying Candidate evidence.
# Upstream assets: immutable ios-fixed225-reference/0.1.0-rc1; reuses an already-fetched validated RC when available.
# Runtime: macOS/Xcode, connected physical iPhone18,4, Release build.
# Generated: 2026-10-02 America/New_York.
# Changes: new dedicated Flow scheduler head-to-head runner; comparison order remains 10/8/6 while production default is independently recorded and must now be 6.

# Changes 2026-10-02: reject stale same-commit receipts by host launch epoch and print both acoustic-only and shared-LLM steady-compute RTF for each 10/8/6 variant.

# Changes 2026-10-03: head-to-head host validation rejects receipts that do not identify 6 as the production Flow default.
