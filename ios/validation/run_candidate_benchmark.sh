#@title run_candidate_benchmark.sh
# Requirement: fetch the exact immutable private RC through the ordinary SDK path, install a fresh Release DeviceSmoke build, auto-run two public synthesize calls on one engine, retrieve the receipt and bind it to release metadata.
#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PYTHON="$ROOT/.venv-release/bin/python"
FETCHED="$ROOT/.work/candidate/fetched-runtime"
RAW="$ROOT/.work/candidate/candidate-benchmark-device.json"
OUTPUT="$ROOT/validation/evidence/candidate_benchmark.json"
BUNDLE_ID="${COSYVOICE3_CANDIDATE_BUNDLE_ID:-com.actacomes.cosyvoice3.candidatebenchmark}"
main(){
    [ -n "${DEVELOPMENT_TEAM:-}" ] || { printf '[COSYVOICE3-CANDIDATE-BENCH] ERROR set DEVELOPMENT_TEAM\n'; return 2; }
    [ -n "${DEVICE_ID:-}" ] || { printf '[COSYVOICE3-CANDIDATE-BENCH] ERROR set DEVICE_ID\n'; return 2; }
    [ -n "${COSYVOICE3_REFERENCE_WAV:-}" ] || { printf '[COSYVOICE3-CANDIDATE-BENCH] ERROR set COSYVOICE3_REFERENCE_WAV\n'; return 2; }
    [ -n "${COSYVOICE3_REFERENCE_TRANSCRIPT:-}" ] || { printf '[COSYVOICE3-CANDIDATE-BENCH] ERROR set COSYVOICE3_REFERENCE_TRANSCRIPT\n'; return 2; }
    command -v python3 || return $?; command -v xcrun || return $?; command -v xcodebuild || return $?
    if [ ! -x "$PYTHON" ]; then python3 -m venv "$ROOT/.venv-release" || return $?; fi
    "$PYTHON" -m pip install -r "$ROOT/requirements-release.txt" || return $?
    "$PYTHON" - <<'PY'
from huggingface_hub import HfApi
identity=HfApi().whoami(); name=(identity.get("name") or identity.get("fullname") or "") if isinstance(identity,dict) else (getattr(identity,"name","") or getattr(identity,"fullname",""))
print(f"[COSYVOICE3-CANDIDATE-BENCH] HF identity={name!r}",flush=True)
if name!="actacomes": raise SystemExit("Hugging Face login must be actacomes")
PY
    [ $? -eq 0 ] || return $?
    rm -rf "$FETCHED" || return $?; mkdir -p "$(dirname "$RAW")" "$(dirname "$OUTPUT")" || return $?
    "$PYTHON" "$ROOT/assets/fetch_assets.py" --profile ios-fixed225-reference --version 0.1.0-rc1 --output "$FETCHED" --force || return $?
    COSYVOICE3_PROMOTED_RUNTIME_MODE=1 COSYVOICE3_CANDIDATE_BENCHMARK=1 COSYVOICE3_FRESH_INSTALL=1 COSYVOICE3_ASSET_ROOT="$FETCHED" COSYVOICE3_PYTHON="$PYTHON" CONFIGURATION=Release BUNDLE_ID="$BUNDLE_ID" DERIVED_DATA="$ROOT/.work/CandidateBenchmarkDerivedData" bash "$ROOT/validation/install_device_smoke.sh" || return $?
    rm -f "$RAW" || return $?
    for attempt in $(seq 1 36); do
        printf '[COSYVOICE3-CANDIDATE-BENCH] receipt poll %s/36\n' "$attempt"
        if xcrun devicectl device copy from --device "$DEVICE_ID" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" --source "Documents/candidate-benchmark-receipt.json" --destination "$RAW"; then
            if [ -s "$RAW" ]; then break; fi
        fi
        sleep 10
    done
    [ -s "$RAW" ] || { printf '[COSYVOICE3-CANDIDATE-BENCH] ERROR device benchmark receipt not produced\n'; return 3; }
    "$PYTHON" "$ROOT/validation/record_candidate_benchmark.py" --raw-receipt "$RAW" --asset-root "$FETCHED" --reference-wav "$COSYVOICE3_REFERENCE_WAV" --reference-transcript "$COSYVOICE3_REFERENCE_TRANSCRIPT" --output "$OUTPUT" || return $?
    printf '[COSYVOICE3-CANDIDATE-BENCH] COMPLETE receipt=%s\n' "$OUTPUT"
}
main "$@"
RC=$?
printf '[COSYVOICE3-CANDIDATE-BENCH] rc=%s\n' "$RC"
test "$RC" -eq 0
# Code purpose: produce Candidate cold/warm benchmark evidence from a fresh install of the exact immutable HF private RC using only CosyVoice3Engine public synthesis API.
# Upstream: assets/fetch_assets.py, immutable ios-fixed225-reference/0.1.0-rc1, DeviceSmoke Candidate benchmark mode.
# Runtime: macOS/Xcode, authenticated actacomes Hugging Face access, connected physical iPhone, developer signing identity.
# Generated: 2026-10-02 America/New_York.
# Changes: new file; immutable fetch, fresh Release install, two-call public API benchmark, receipt polling and fail-closed metadata binding.\n# Changes 2026-10-02: pass the exact local reference WAV/transcript to the recorder so Candidate evidence stores reproducible workload hashes without storing private transcript content.
