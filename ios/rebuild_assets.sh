#@title rebuild_assets.sh
# Requirement: one command must reconstruct the complete ios-fixed225-reference runtime from pinned source/model/toolchain inputs without reading any historical CosyVoice3_NPU iOS/converted directory.
#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"
PROFILE="${2:-}"
[ "${1:-}" = "--profile" ] || { printf '[COSYVOICE3-REBUILD] usage: bash rebuild_assets.sh --profile ios-fixed225-reference\n'; return 2 2>/dev/null || true; }
[ "$PROFILE" = "ios-fixed225-reference" ] || { printf '[COSYVOICE3-REBUILD] ERROR unsupported profile=%s\n' "$PROFILE"; return 2 2>/dev/null || true; }
SOURCE_COMMIT="878940245562bcd1dd0231d78157ba78d70b39f6"
MODEL_REPO="FunAudioLLM/Fun-CosyVoice3-0.5B-2512"
MODEL_REVISION="29e01c4e8d000f4bcd70751be16fa94bf3d85a18"
WORK="${COSYVOICE3_REBUILD_WORK:-$ROOT/.work/rebuild/$PROFILE}"
SOURCE="$WORK/source"
VENV="$WORK/venv"
REF_VENV="$WORK/reference-venv"
FIXTURE="$WORK/fixture"
REF="$WORK/reference"
OUTPUT="${COSYVOICE3_REBUILD_OUTPUT:-$ROOT/.work/rebuilt-runtime/$PROFILE}"
RECEIPT="${COSYVOICE3_REBUILD_RECEIPT:-$ROOT/validation/evidence/full_runtime_rebuild.json}"
PYTHON_BOOTSTRAP="${PYTHON_BOOTSTRAP:-python3.11}"
log(){ printf '[COSYVOICE3-REBUILD] %s\n' "$*"; }
fail(){ printf '[COSYVOICE3-REBUILD] ERROR %s\n' "$1"; return 1; }
run(){ log "RUN $*"; "$@"; }
main(){
    [ "${1:-}" = "--profile" ] && [ -n "${2:-}" ] || { printf \'[COSYVOICE3-REBUILD] usage: bash rebuild_assets.sh --profile ios-fixed225-reference\\n\'; return 2; }
    PROFILE="$2"; [ "$PROFILE" = "ios-fixed225-reference" ] || { printf \'[COSYVOICE3-REBUILD] ERROR unsupported profile=%s\\n\' "$PROFILE"; return 2; }
    command -v git || return $?; command -v "$PYTHON_BOOTSTRAP" || return $?; command -v xcodebuild || return $?; command -v swift || return $?
    mkdir -p "$WORK" "$(dirname "$OUTPUT")" "$(dirname "$RECEIPT")" || return $?
    if [ ! -x "$VENV/bin/python" ]; then run "$PYTHON_BOOTSTRAP" -m venv "$VENV" || return $?; fi
    run "$VENV/bin/python" -m pip install "pip<26" "setuptools==80.9.0" wheel || return $?
    run "$VENV/bin/python" -m pip install -r "$ROOT/requirements-rebuild.txt" || return $?
    rm -rf "$SOURCE" "$FIXTURE" "$REF" "$OUTPUT" || return $?
    run git clone https://github.com/Ashtabula/CosyVoice3_NPU.git "$SOURCE" || return $?
    run git -C "$SOURCE" checkout --detach "$SOURCE_COMMIT" || return $?
    run git -C "$SOURCE" submodule update --init --recursive || return $?
    [ "$(git -C "$SOURCE" rev-parse HEAD)" = "$SOURCE_COMMIT" ] || { fail "source checkout mismatch"; return 1; }
    log "download exact model revision=$MODEL_REVISION"
    "$VENV/bin/python" - "$SOURCE" "$MODEL_REPO" "$MODEL_REVISION" <<'PY'
from pathlib import Path
import json,sys
from huggingface_hub import HfApi,snapshot_download
source=Path(sys.argv[1]); repo=sys.argv[2]; revision=sys.argv[3]
info=HfApi().model_info(repo,revision=revision)
if info.sha!=revision: raise SystemExit(f"model revision mismatch {info.sha} != {revision}")
dest=source/"pretrained_models/Fun-CosyVoice3-0.5B-2512"
snapshot_download(repo_id=repo,revision=revision,local_dir=dest)
required=["llm.pt","flow.pt","hift.pt","cosyvoice3.yaml","speech_tokenizer_v3.onnx","campplus.onnx","CosyVoice-BlankEN/config.json"]
missing=[name for name in required if not (dest/name).exists()]
if missing: raise SystemExit("missing model files: "+repr(missing))
lock=source/"iOS/validation/provenance/checkpoint-lock.json"; lock.parent.mkdir(parents=True,exist_ok=True); lock.write_text(json.dumps({"repo":repo,"revision":revision,"download_verified":True},indent=2)+"\n")
print(f"[COSYVOICE3-REBUILD] MODEL_PASS repo={repo} revision={revision} root={dest}",flush=True)
PY
    [ $? -eq 0 ] || return $?
    log "generate deterministic production-shape validation fixture"
    run "$VENV/bin/python" "$ROOT/validation/generate_rebuild_validation_fixture.py" --source-root "$SOURCE" --output "$FIXTURE" || return $?
    mkdir -p "$SOURCE/iOS/validation/phase0/run-002" || return $?
    ln -s "$FIXTURE" "$SOURCE/iOS/validation/phase0/run-002/tensors" || return $?
    log "rebuild final LLM prefill/decode family"
    run "$VENV/bin/python" "$SOURCE/iOS/tools/prepare_llm_fp16_device_inputs.py" || return $?
    run "$VENV/bin/python" "$SOURCE/iOS/tools/export_llm_stateful_prefill_fp16.py" || return $?
    run "$VENV/bin/python" "$SOURCE/iOS/tools/export_llm_stateful_fp16.py" --convert || return $?
    run "$VENV/bin/python" "$SOURCE/iOS/tools/export_llm_ane_full24.py" || return $?
    run "$VENV/bin/python" "$SOURCE/iOS/tools/validate_llm_ane_full24.py" || return $?
    run "$VENV/bin/python" "$SOURCE/iOS/tools/optimize_llm_decode.py" --variant perlayer || return $?
    run "$VENV/bin/python" "$SOURCE/iOS/tools/export_llm_shape_counterfactual.py" --kind fixed --length 449 || return $?
    run "$VENV/bin/python" "$SOURCE/iOS/tools/export_llm_mask_write_probe.py" --length 449 || return $?
    run "$VENV/bin/python" "$SOURCE/iOS/tools/export_llm_mask_write512.py" || return $?
    log "rebuild 22-block FP16 Flow and six production shards"
    run "$VENV/bin/python" "$SOURCE/iOS/tools/probe_flow_fixed_752.py" --blocks 22 --precision fp16 --export || return $?
    run "$VENV/bin/python" "$SOURCE/iOS/tools/export_flow_fp16_shards.py" --export --validate-coreml || return $?
    log "rebuild Flow conditioning, host-phase HiFT and FP64 F0 coefficients"
    run "$VENV/bin/python" "$SOURCE/iOS/tools/export_pipeline_acoustics.py" || return $?
    run "$VENV/bin/python" "$SOURCE/iOS/tools/export_pipeline_acoustics.py" --host-phase || return $?
    run "$VENV/bin/python" "$SOURCE/iOS/tools/export_pipeline_acoustics.py" --export-f0-double || return $?
    log "assemble freshly rebuilt base runtime"
    run "$VENV/bin/python" "$ROOT/validation/assemble_fixed225_runtime_from_migration.py" --source-root "$SOURCE" --output "$OUTPUT" --force || return $?
    log "build and host-validate custom-reference assets in the separately pinned Core ML reference environment"
    COSYVOICE3_PUBLICATION_ROOT="$ROOT/.." COSYVOICE3_REFERENCE_VENV="$REF_VENV" bash "$ROOT/tools/bootstrap_reference_env_macos.sh" || return $?
    mkdir -p "$REF/coreml" "$REF/parity" || return $?
    "$REF_VENV/bin/python" "$ROOT/tools/convert_reference_onnx_to_coreml.py" --speech-tokenizer "$SOURCE/pretrained_models/Fun-CosyVoice3-0.5B-2512/speech_tokenizer_v3.onnx" --campplus "$SOURCE/pretrained_models/Fun-CosyVoice3-0.5B-2512/campplus.onnx" --output "$REF/coreml" || return $?
    "$REF_VENV/bin/python" "$ROOT/tools/export_dynamic_flow_conditions.py" --model-dir "$SOURCE/pretrained_models/Fun-CosyVoice3-0.5B-2512" --output "$REF/coreml/flow-conditions-dynamic-151-302.mlpackage" --prompt-token-count 151 --prompt-frame-count 302 || return $?
    "$REF_VENV/bin/python" "$ROOT/tools/run_reference_release_gate.py" --source-root "$SOURCE" --model-dir "$SOURCE/pretrained_models/Fun-CosyVoice3-0.5B-2512" --coreml-dir "$REF/coreml" --work "$REF/parity" || return $?
    cp "$REF/parity/fixture/whisper_mel_128.f32" "$REF/coreml/" || return $?
    cp "$REF/parity/fixture/kaldi_mel_80.f32" "$REF/coreml/" || return $?
    cp "$REF/parity/fixture/matcha_mel_80.f32" "$REF/coreml/" || return $?
    run "$VENV/bin/python" "$ROOT/validation/install_rebuilt_reference_assets.py" --asset-root "$OUTPUT" --reference-dir "$REF/coreml" --host-receipt "$REF/parity/reference_host_parity_receipt.json" || return $?
    run "$VENV/bin/python" "$ROOT/assets/validate_assets.py" --root "$OUTPUT" || return $?
    run "$VENV/bin/python" "$ROOT/validation/record_full_runtime_rebuild.py" --asset-root "$OUTPUT" --source-root "$SOURCE" --host-receipt "$REF/parity/reference_host_parity_receipt.json" --output "$RECEIPT" || return $?
    log "COMPLETE status=PASS_SUPPORTED_FULL_RUNTIME_REBUILD profile=$PROFILE output=$OUTPUT receipt=$RECEIPT"
}
main "$@"
RC=$?
printf '[COSYVOICE3-REBUILD] rc=%s\n' "$RC"
test "$RC" -eq 0
# Code purpose: reconstruct the complete fixed225 iOS SDK runtime from an exact source commit, exact model revision and pinned converters, then emit supported-rebuild evidence.
# Upstream: Ashtabula/CosyVoice3_NPU@878940245562bcd1dd0231d78157ba78d70b39f6 and FunAudioLLM/Fun-CosyVoice3-0.5B-2512@29e01c4e8d000f4bcd70751be16fa94bf3d85a18.
# Runtime: Apple Silicon macOS, Xcode, Python 3.11; project-local .work virtual environments only.
# Generated: 2026-10-02 America/New_York.
# Changes: new file; fresh source clone, exact model download, deterministic no-private-audio validation fixture, final maskwrite512 LLM, six-shard FP16 Flow, conditioning/HiFT/FP64-F0, custom-reference host parity, canonical assembly/validation and Candidate rebuild receipt.\n# Changes 2026-10-02: moved CLI validation inside main() and removed stderr redirection/top-level return compatibility logic; all command diagnostics remain visible.
