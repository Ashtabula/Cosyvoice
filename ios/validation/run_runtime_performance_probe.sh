#@title run_runtime_performance_probe.sh
# Requirement: measure fresh-install cold, same-engine warm, and same-install process-relaunch cold/warm performance without writing Candidate release evidence or changing the immutable RC.
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PYTHON="$ROOT/.venv-release/bin/python"
WORK="$ROOT/.work/runtime-performance"
FETCHED="$WORK/fetched-runtime"
FRESH="$WORK/fresh-install.json"
RELAUNCH="$WORK/same-install-relaunch.json"
SUMMARY="$WORK/summary.json"
BUNDLE_ID="${COSYVOICE3_CANDIDATE_BUNDLE_ID:-com.actacomes.cosyvoice3.candidatebenchmark}"

poll_receipt(){
    local output="$1" label="$2"
    rm -f "$output"
    for attempt in $(seq 1 48); do
        printf '[COSYVOICE3-PERF] %s receipt poll %s/48\n' "$label" "$attempt"
        if xcrun devicectl device copy from --device "$DEVICE_ID" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" --source "Documents/candidate-benchmark-receipt.json" --destination "$output"; then
            if [ -s "$output" ]; then
                "$PYTHON" - "$output" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]))
if p.get("status")!="PASS_CANDIDATE_BENCHMARK":
    raise SystemExit("benchmark receipt is not PASS: "+str(p.get("status")))
print("[COSYVOICE3-PERF] RECEIPT",json.dumps({
    "sourceCommit":p.get("sourceCommit"),
    "firstRTF":p.get("firstRTF"),
    "repeatRTF":p.get("repeatRTF"),
    "firstMs":p.get("firstSynthesisMilliseconds"),
    "repeatMs":p.get("repeatSynthesisMilliseconds"),
    "firstStages":p.get("firstStages"),
    "repeatStages":p.get("repeatStages"),
},sort_keys=True),flush=True)
PY
                return 0
            fi
        fi
        sleep 5
    done
    printf '[COSYVOICE3-PERF] ERROR %s receipt not produced\n' "$label"
    return 3
}

main(){
    [ -n "${DEVELOPMENT_TEAM:-}" ] || { printf '[COSYVOICE3-PERF] ERROR set DEVELOPMENT_TEAM\n'; return 2; }
    [ -n "${DEVICE_ID:-}" ] || { printf '[COSYVOICE3-PERF] ERROR set DEVICE_ID\n'; return 2; }
    [ -n "${COSYVOICE3_REFERENCE_WAV:-}" ] || { printf '[COSYVOICE3-PERF] ERROR set COSYVOICE3_REFERENCE_WAV\n'; return 2; }
    [ -n "${COSYVOICE3_REFERENCE_TRANSCRIPT:-}" ] || { printf '[COSYVOICE3-PERF] ERROR set COSYVOICE3_REFERENCE_TRANSCRIPT\n'; return 2; }
    command -v python3
    command -v xcrun
    command -v xcodebuild

    if [ ! -x "$PYTHON" ]; then python3 -m venv "$ROOT/.venv-release"; fi
    "$PYTHON" -m pip install -r "$ROOT/requirements-release.txt"

    "$PYTHON" - <<'PY'
from huggingface_hub import HfApi
identity=HfApi().whoami()
name=(identity.get("name") or identity.get("fullname") or "") if isinstance(identity,dict) else (getattr(identity,"name","") or getattr(identity,"fullname",""))
print(f"[COSYVOICE3-PERF] HF identity={name!r}",flush=True)
if name!="actacomes":
    raise SystemExit("Hugging Face login must be actacomes")
PY

    rm -rf "$WORK"
    mkdir -p "$WORK"
    "$PYTHON" "$ROOT/assets/fetch_assets.py" --profile ios-fixed225-reference --version 0.1.0-rc1 --output "$FETCHED" --force

    DECODE_PROFILE="maskwrite512-rc1"
    if [ "${COSYVOICE3_PERF_FIXED449:-0}" = "1" ]; then
        DECODE449="${COSYVOICE3_PERF_FIXED449_SOURCE:-$ROOT/.work/rebuild/ios-fixed225-reference/source/iOS/converted/llm_fp16/llm-opt-perlayer-decode-maskwrite449.mlpackage}"
        "$PYTHON" "$ROOT/validation/prepare_fixed449_performance_runtime.py" --runtime "$FETCHED" --decode449 "$DECODE449"
        DECODE_PROFILE="maskwrite449-diagnostic"
    fi

    printf '[COSYVOICE3-PERF] PHASE fresh-install\n'
    COSYVOICE3_PROMOTED_RUNTIME_MODE=1 \
    COSYVOICE3_CANDIDATE_BENCHMARK=1 \
    COSYVOICE3_FRESH_INSTALL=1 \
    COSYVOICE3_ASSET_ROOT="$FETCHED" \
    COSYVOICE3_PYTHON="$PYTHON" \
    CONFIGURATION=Release \
    BUNDLE_ID="$BUNDLE_ID" \
    DERIVED_DATA="$ROOT/.work/RuntimePerformanceDerivedData" \
    bash "$ROOT/validation/install_device_smoke.sh"

    poll_receipt "$FRESH" fresh-install

    # Relaunch the already-installed bundle. Application Support and Library/Caches
    # remain intact; DeviceSmoke deletes the old receipt at run start.
    printf '[COSYVOICE3-PERF] PHASE same-install-process-relaunch\n'
    xcrun devicectl device process launch --terminate-existing --device "$DEVICE_ID" "$BUNDLE_ID"
    sleep 2
    poll_receipt "$RELAUNCH" same-install-relaunch

    "$PYTHON" - "$FRESH" "$RELAUNCH" "$SUMMARY" "$(git -C "$ROOT/.." rev-parse HEAD)" "$DECODE_PROFILE" <<'PY'
import json,sys,time
fresh=json.load(open(sys.argv[1]))
relaunch=json.load(open(sys.argv[2]))
summary={
    "schemaVersion":1,
    "status":"PASS_RUNTIME_PERFORMANCE_PROBE",
    "sourceCommit":sys.argv[4],
    "decodeProfile":sys.argv[5],
    "recordedAtUnix":int(time.time()),
    "scope":"diagnostic only; immutable RC assets; no Candidate release evidence written",
    "freshInstall":fresh,
    "sameInstallProcessRelaunch":relaunch,
}
with open(sys.argv[3],"w") as f:
    json.dump(summary,f,indent=2,sort_keys=True)
    f.write("\n")
print("[COSYVOICE3-PERF] PASS",json.dumps({
    "decodeProfile":sys.argv[5],
    "freshFirstRTF":fresh.get("firstRTF"),
    "freshWarmRTF":fresh.get("repeatRTF"),
    "relaunchFirstRTF":relaunch.get("firstRTF"),
    "relaunchWarmRTF":relaunch.get("repeatRTF"),
    "freshFirstStages":fresh.get("firstStages"),
    "relaunchFirstStages":relaunch.get("firstStages"),
},sort_keys=True),flush=True)
PY
    printf '[COSYVOICE3-PERF] summary=%s\n' "$SUMMARY"
}
main "$@"

# Code purpose: diagnostic public-API performance probe separating fresh-install first use, same-engine warm synthesis, and same-install process relaunch; it deliberately does not update validation/evidence/candidate_benchmark.json.
# Upstream assets: immutable private HF ios-fixed225-reference/0.1.0-rc1.
# Runtime: macOS/Xcode, connected physical iPhone, actacomes HF authentication.
# Generated: 2026-10-02 America/New_York.\n# Changes 2026-10-02: optional COSYVOICE3_PERF_FIXED449=1 swaps only the decode package to the previously device/audio-accepted <=449 candidate for diagnostic A/B; the script still never writes Candidate evidence.\n