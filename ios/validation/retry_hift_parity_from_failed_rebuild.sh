#!/usr/bin/env bash
#@title retry_hift_parity_from_failed_rebuild.sh
# Requirement: after a late clean-house HiFT parity failure, reuse only the pinned temporary source + persistent checkpoint cache, regenerate the deterministic fixture with the current publication code, and rerun acoustic/HiFT host parity without rerunning LLM Core ML exports.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${COSYVOICE3_REBUILD_WORK:-$ROOT/.work/rebuild/ios-fixed225-reference}"
SOURCE="$WORK/source"
VENV="$WORK/venv"
FIXTURE="$WORK/fixture"
MODEL_CACHE="$WORK/model-cache/Fun-CosyVoice3-0.5B-2512"
HYGIENE="$WORK/source-hygiene.json"
SOURCE_COMMIT="878940245562bcd1dd0231d78157ba78d70b39f6"

log(){ printf '[COSYVOICE3-HIFT-RETRY] %s\n' "$*"; }
run(){ log "RUN $*"; "$@"; }

[ -x "$VENV/bin/python" ] || { log "ERROR missing rebuild venv"; exit 1; }
[ -d "$SOURCE/.git" ] || { log "ERROR missing failed-run pinned source checkout"; exit 1; }
[ "$(git -C "$SOURCE" rev-parse HEAD)" = "$SOURCE_COMMIT" ] || { log "ERROR source commit mismatch"; exit 1; }
[ -d "$MODEL_CACHE" ] || { log "ERROR missing persistent model cache"; exit 1; }
[ -f "$HYGIENE" ] || { log "ERROR missing source hygiene receipt"; exit 1; }

run "$VENV/bin/python" - "$HYGIENE" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]))
if p.get("schemaVersion")!=6 or p.get("status")!="PASS_SOURCE_HYGIENE" or p.get("runtimePrefixRngConstructionExpected") is not True:
    raise SystemExit(f"source hygiene is not current runtime-prefix schema6: {p}")
print("[COSYVOICE3-HIFT-RETRY] SOURCE_HYGIENE_SCHEMA6_PASS",flush=True)
PY

log "regenerate runtime-prefix YAML and model-generated deterministic Flow/HiFT fixture"
run "$VENV/bin/python" "$ROOT/validation/prepare_acoustic_rebuild_config.py" --model-dir "$MODEL_CACHE" --output "$MODEL_CACHE/cosyvoice3.acoustic.yaml"
rm -rf "$FIXTURE"
run "$VENV/bin/python" "$ROOT/validation/generate_rebuild_validation_fixture.py" --source-root "$SOURCE" --output "$FIXTURE"

if [ -L "$SOURCE/iOS/validation/phase0/run-002/tensors" ]; then
    :
elif [ -e "$SOURCE/iOS/validation/phase0/run-002/tensors" ]; then
    log "ERROR phase0 tensors path exists but is not the clean-house fixture symlink"; exit 1
else
    mkdir -p "$SOURCE/iOS/validation/phase0/run-002"
    ln -s "$FIXTURE" "$SOURCE/iOS/validation/phase0/run-002/tensors"
fi

log "remove only temporary acoustic outputs/receipts so this retry cannot reuse the failed HiFT package"
rm -rf "$SOURCE/iOS/converted/full-pipeline"
rm -f "$SOURCE/iOS/validation/full-pipeline/acoustics-export.json" \
      "$SOURCE/iOS/validation/full-pipeline/host-hift-phase-host.json" \
      "$SOURCE/iOS/validation/full-pipeline/f0-double-export.json"

run "$VENV/bin/python" "$SOURCE/iOS/tools/export_pipeline_acoustics.py"
run "$VENV/bin/python" "$SOURCE/iOS/tools/export_pipeline_acoustics.py" --host-phase
run "$VENV/bin/python" "$SOURCE/iOS/tools/export_pipeline_acoustics.py" --export-f0-double

run "$VENV/bin/python" - "$SOURCE/iOS/validation/full-pipeline/host-hift-phase-host.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]))
def gate(name,max_abs,rel):
    m=p.get(name) or {}
    if m.get("finite") is False or float(m.get("max_abs",999))>max_abs or float(m.get("relative_l2",999))>rel:
        raise SystemExit(f"{name} FAIL {m}")
    print(f"[COSYVOICE3-HIFT-RETRY] {name} PASS {m}",flush=True)
if p.get("status")!="HOST_PHASE_CANDIDATE":
    raise SystemExit(f"unexpected host phase status: {p.get('status')}")
gate("f0_vs_torch",0.005,1e-5)
gate("coreml_chain_vs_torch_fp32_f0",0.03,0.02)
gate("vs_upstream_fp64_f0",0.03,0.02)
print("[COSYVOICE3-HIFT-RETRY] PASS_STRICT_HIFT_HOST_PARITY",flush=True)
PY

# Code purpose: quickly validate the corrected clean-house Flow-derived HiFT fixture after a late HiFT failure, without rerunning already-proven LLM/Flow Core ML exports.
# Upstream source: pinned temporary CosyVoice3_NPU checkout plus persistent official checkpoint cache created by ios/rebuild_assets.sh.
# Runtime environment: macOS Apple Silicon / existing isolated rebuild Python 3.11 venv / Core ML Tools 9.
# Generated: 2026-10-02 America/New_York.
# Changes: new diagnostic retry; deletes/rebuilds only temporary fixture and acoustic outputs, preserves strict production HiFT thresholds, and does not emit full-runtime Candidate PASS.
