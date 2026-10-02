#@title rebuild_assets.sh
# Requirement: one command must reconstruct the complete ios-fixed225-reference runtime from pinned source/model/toolchain inputs without reading any historical CosyVoice3_NPU iOS/converted directory.
#!/usr/bin/env bash
set -u
unset PYTHONPATH PYTHONHOME
export PYTHONNOUSERSITE=1
ROOT="$(cd "$(dirname "$0")" && pwd)"
SOURCE_COMMIT="878940245562bcd1dd0231d78157ba78d70b39f6"
MODEL_REPO="FunAudioLLM/Fun-CosyVoice3-0.5B-2512"
MODEL_REVISION="29e01c4e8d000f4bcd70751be16fa94bf3d85a18"
PYTHON_BOOTSTRAP="${PYTHON_BOOTSTRAP:-python3.11}"
log(){ printf '[COSYVOICE3-REBUILD] %s\n' "$*"; }
fail(){ printf '[COSYVOICE3-REBUILD] ERROR %s\n' "$1"; return 1; }
run(){ log "RUN $*"; "$@"; }
main(){
    [ "${1:-}" = "--profile" ] && [ -n "${2:-}" ] || { printf '[COSYVOICE3-REBUILD] usage: bash rebuild_assets.sh --profile ios-fixed225-reference\n'; return 2; }
    local profile="$2"; [ "$profile" = "ios-fixed225-reference" ] || { printf '[COSYVOICE3-REBUILD] ERROR unsupported profile=%s\n' "$profile"; return 2; }
    local work source venv ref_venv fixture ref output receipt hygiene model_cache legacy_model
    work="${COSYVOICE3_REBUILD_WORK:-$ROOT/.work/rebuild/$profile}"
    source="$work/source"
    venv="$work/venv"
    ref_venv="$work/reference-venv"
    fixture="$work/fixture"
    ref="$work/reference"
    output="${COSYVOICE3_REBUILD_OUTPUT:-$ROOT/.work/rebuilt-runtime/$profile}"
    receipt="${COSYVOICE3_REBUILD_RECEIPT:-$ROOT/validation/evidence/full_runtime_rebuild.json}"
    hygiene="$work/source-hygiene.json"
    model_cache="$work/model-cache/Fun-CosyVoice3-0.5B-2512"
    legacy_model="$source/pretrained_models/Fun-CosyVoice3-0.5B-2512"
    command -v git || return $?; command -v "$PYTHON_BOOTSTRAP" || return $?; command -v xcodebuild || return $?; command -v swift || return $?
    mkdir -p "$work" "$(dirname "$output")" "$(dirname "$receipt")" || return $?
    if [ ! -x "$venv/bin/python" ]; then run "$PYTHON_BOOTSTRAP" -m venv "$venv" || return $?; fi
    run "$venv/bin/python" -m pip install "pip<26" "setuptools==80.9.0" wheel || return $?
    run "$venv/bin/python" -m pip install -r "$ROOT/requirements-rebuild.txt" || return $?
    run "$venv/bin/python" -c 'import conformer,diffusers,lightning,PIL; print("[COSYVOICE3-REBUILD] LOCAL_DEPS conformer="+conformer.__file__+" diffusers="+diffusers.__version__+" lightning="+lightning.__version__+" pillow="+PIL.__version__)' || return $?
    if [ -d "$legacy_model" ] && [ ! -e "$model_cache" ]; then mkdir -p "$(dirname "$model_cache")" || return $?; log "preserve prior model download $legacy_model -> $model_cache"; mv "$legacy_model" "$model_cache" || return $?; fi
    rm -rf "$source" "$fixture" "$ref" "$output" || return $?
    run git clone https://github.com/Ashtabula/CosyVoice3_NPU.git "$source" || return $?
    run git -C "$source" checkout --detach "$SOURCE_COMMIT" || return $?
    run git -C "$source" submodule update --init --recursive || return $?
    [ "$(git -C "$source" rev-parse HEAD)" = "$SOURCE_COMMIT" ] || { fail "source checkout mismatch"; return 1; }
    run "$venv/bin/python" "$ROOT/validation/sanitize_rebuild_source.py" --source-root "$source" --output "$hygiene" || return $?
    run "$venv/bin/python" "$ROOT/validation/smoke_rebuild_python_imports.py" --source-root "$source" || return $?
    log "download exact minimal model revision=$MODEL_REVISION"
    run "$venv/bin/python" "$ROOT/validation/fetch_rebuild_checkpoint.py" --source-root "$source" --model-cache "$model_cache" --repo "$MODEL_REPO" --revision "$MODEL_REVISION" || return $?
    run "$venv/bin/python" "$ROOT/validation/generate_rebuild_validation_fixture.py" --source-root "$source" --output "$fixture" || return $?
    mkdir -p "$source/iOS/validation/phase0/run-002" || return $?; ln -s "$fixture" "$source/iOS/validation/phase0/run-002/tensors" || return $?
    log "rebuild final LLM prefill/decode family"
    run "$venv/bin/python" "$source/iOS/tools/prepare_llm_fp16_device_inputs.py" || return $?
    run "$venv/bin/python" "$source/iOS/tools/export_llm_stateful_prefill_fp16.py" || return $?
    run "$venv/bin/python" "$source/iOS/tools/export_llm_stateful_fp16.py" --convert || return $?
    run "$venv/bin/python" "$source/iOS/tools/export_llm_ane_full24.py" || return $?
    run "$venv/bin/python" "$source/iOS/tools/validate_llm_ane_full24.py" || return $?
    run "$venv/bin/python" "$source/iOS/tools/optimize_llm_decode.py" --variant perlayer || return $?
    run "$venv/bin/python" "$source/iOS/tools/export_llm_shape_counterfactual.py" --kind fixed --length 449 || return $?
    run "$venv/bin/python" "$source/iOS/tools/export_llm_mask_write_probe.py" --length 449 || return $?
    run "$venv/bin/python" "$source/iOS/tools/export_llm_mask_write512.py" || return $?
    log "rebuild 22-block FP16 Flow and six production shards"
    run "$venv/bin/python" "$source/iOS/tools/probe_flow_fixed_752.py" --blocks 22 --precision fp16 --export || return $?
    run "$venv/bin/python" "$source/iOS/tools/export_flow_fp16_shards.py" --export --validate-coreml || return $?
    log "rebuild Flow conditioning, host-phase HiFT and FP64 F0 coefficients"
    run "$venv/bin/python" "$source/iOS/tools/export_pipeline_acoustics.py" || return $?
    run "$venv/bin/python" "$source/iOS/tools/export_pipeline_acoustics.py" --host-phase || return $?
    run "$venv/bin/python" "$source/iOS/tools/export_pipeline_acoustics.py" --export-f0-double || return $?
    run "$venv/bin/python" "$ROOT/validation/assemble_fixed225_runtime_from_migration.py" --source-root "$source" --output "$output" --force || return $?
    log "rebuild and host-validate custom-reference assets"
    COSYVOICE3_PUBLICATION_ROOT="$ROOT/.." COSYVOICE3_REFERENCE_VENV="$ref_venv" bash "$ROOT/tools/bootstrap_reference_env_macos.sh" || return $?
    mkdir -p "$ref/coreml" "$ref/parity" || return $?
    "$ref_venv/bin/python" "$ROOT/tools/convert_reference_onnx_to_coreml.py" --speech-tokenizer "$source/pretrained_models/Fun-CosyVoice3-0.5B-2512/speech_tokenizer_v3.onnx" --campplus "$source/pretrained_models/Fun-CosyVoice3-0.5B-2512/campplus.onnx" --output "$ref/coreml" || return $?
    "$ref_venv/bin/python" "$ROOT/tools/export_dynamic_flow_conditions.py" --model-dir "$source/pretrained_models/Fun-CosyVoice3-0.5B-2512" --output "$ref/coreml/flow-conditions-dynamic-151-302.mlpackage" --prompt-token-count 151 --prompt-frame-count 302 || return $?
    "$ref_venv/bin/python" "$ROOT/tools/run_reference_release_gate.py" --source-root "$source" --model-dir "$source/pretrained_models/Fun-CosyVoice3-0.5B-2512" --coreml-dir "$ref/coreml" --work "$ref/parity" || return $?
    cp "$ref/parity/fixture/whisper_mel_128.f32" "$ref/coreml/" || return $?; cp "$ref/parity/fixture/kaldi_mel_80.f32" "$ref/coreml/" || return $?; cp "$ref/parity/fixture/matcha_mel_80.f32" "$ref/coreml/" || return $?
    run "$venv/bin/python" "$ROOT/validation/install_rebuilt_reference_assets.py" --asset-root "$output" --reference-dir "$ref/coreml" --host-receipt "$ref/parity/reference_host_parity_receipt.json" || return $?
    run "$venv/bin/python" "$ROOT/assets/validate_assets.py" --root "$output" || return $?
    run "$venv/bin/python" "$ROOT/validation/record_full_runtime_rebuild.py" --asset-root "$output" --source-root "$source" --host-receipt "$ref/parity/reference_host_parity_receipt.json" --source-hygiene-receipt "$hygiene" --output "$receipt" || return $?
    log "COMPLETE status=PASS_SUPPORTED_FULL_RUNTIME_REBUILD profile=$profile output=$output receipt=$receipt"
}
main "$@"
RC=$?
printf '[COSYVOICE3-REBUILD] rc=%s\n' "$RC"
test "$RC" -eq 0
# Code purpose: reconstruct the complete fixed225 iOS SDK runtime from an exact source commit, exact model revision and pinned converters, then emit supported-rebuild evidence.
# Upstream: Ashtabula/CosyVoice3_NPU@878940245562bcd1dd0231d78157ba78d70b39f6 and FunAudioLLM/Fun-CosyVoice3-0.5B-2512@29e01c4e8d000f4bcd70751be16fa94bf3d85a18.
# Runtime: Apple Silicon macOS, Xcode, Python 3.11; project-local .work virtual environments only.
# Generated: 2026-10-02 America/New_York.
# Changes: full clean rewrite; all CLI handling lives inside main(), all diagnostics remain visible, no historical converted directory or private reference audio is read, and the accepted LLM/Flow/HiFT/F0/reference converter chain feeds canonical assembly/validation plus a Candidate rebuild receipt.\n# Changes 2026-10-02: lines 18-27 use real physical newlines and assign work before every dependent path under set -u; this fixes the prior patch that accidentally committed literal backslash-n text.
# Changes 2026-10-02: clear inherited PYTHONPATH/PYTHONHOME, disable user site packages, verify local diffusers/Pillow, sanitize the exact pinned upstream developer-local sys.path append, and bind that hygiene receipt into full-runtime rebuild evidence.
# Changes 2026-10-02: replace whole-repository Hugging Face download with a 12-pattern persistent local_dir, migrate any previous failed-run model directory before deleting the temporary source checkout, preflight the complete Matcha/CosyVoice import closure before model download, and reuse interrupted blobs across retries.
