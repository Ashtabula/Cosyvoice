#!/usr/bin/env bash
# run_reference_release_mac.sh
# Requirement: generate fixed-profile custom-reference Core ML candidates and run every host-side parity gate from a pinned CosyVoice3 source tree.
set -euo pipefail

PUBLICATION_ROOT="${COSYVOICE3_PUBLICATION_ROOT:-/Volumes/WD/Codes/Cosyvoice}"
SOURCE_REPO="${COSYVOICE3_SOURCE_REPO:-/Volumes/WD/Codes/CosyVoice3_NPU}"
SOURCE_COMMIT="878940245562bcd1dd0231d78157ba78d70b39f6"
MODEL_REVISION="29e01c4e8d000f4bcd70751be16fa94bf3d85a18"
PINNED_SOURCE="${COSYVOICE3_PINNED_SOURCE:-$PUBLICATION_ROOT/ios/.work/source-$SOURCE_COMMIT}"
WORK="${COSYVOICE3_REFERENCE_WORK:-$PUBLICATION_ROOT/ios/.work/reference-release}"
COREML="$WORK/coreml"
PARITY="$WORK/parity"
FORCE_REBUILD="${COSYVOICE3_FORCE_REBUILD:-0}"

log() { printf '[COSYVOICE3-REFERENCE-MAC] %s\n' "$*"; }
fail() { printf '[COSYVOICE3-REFERENCE-MAC] ERROR %s\n' "$*" >&2; exit 2; }

require_file() {
    [ -f "$1" ] || fail "missing file: $1"
}

stage1_ready() {
    [ "$FORCE_REBUILD" != "1" ] || return 1
    [ -f "$COREML/reference_coreml_conversion.json" ] || return 1
    [ -d "$COREML/speech-tokenizer-fixed605.mlpackage" ] || return 1
    [ -d "$COREML/campplus-fixed604.mlpackage" ] || return 1
    python3 - "$COREML/reference_coreml_conversion.json" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
value = json.loads(path.read_text())
raise SystemExit(0 if value.get("status") == "CONVERTED_NOT_PARITY_VALIDATED" else 1)
PY
}

discover_model_dir() {
    if [ -n "${MODEL_DIR:-}" ]; then
        printf '%s\n' "$MODEL_DIR"
        return
    fi
    for candidate in \
        "$SOURCE_REPO/pretrained_models/Fun-CosyVoice3-0.5B-2512" \
        "$HOME/.cache/huggingface/hub/models--FunAudioLLM--Fun-CosyVoice3-0.5B-2512/snapshots/$MODEL_REVISION" \
        "/Volumes/WD/Models/Fun-CosyVoice3-0.5B-2512" \
        "/Volumes/WD/Codes/models/Fun-CosyVoice3-0.5B-2512"
    do
        if [ -f "$candidate/speech_tokenizer_v3.onnx" ] && \
           [ -f "$candidate/campplus.onnx" ] && \
           [ -f "$candidate/flow.pt" ] && \
           [ -f "$candidate/cosyvoice3.yaml" ]; then
            printf '%s\n' "$candidate"
            return
        fi
    done
    return 1
}

prepare_publication() {
    if [ ! -d "$PUBLICATION_ROOT/.git" ]; then
        mkdir -p "$(dirname "$PUBLICATION_ROOT")"
        git clone https://github.com/Ashtabula/Cosyvoice.git "$PUBLICATION_ROOT"
    fi
    git -C "$PUBLICATION_ROOT" fetch origin main
    git -C "$PUBLICATION_ROOT" checkout main
    git -C "$PUBLICATION_ROOT" pull --ff-only origin main
    log "publication HEAD=$(git -C "$PUBLICATION_ROOT" rev-parse HEAD)"
}

prepare_pinned_source() {
    [ -d "$SOURCE_REPO/.git" ] || fail "source repo missing: $SOURCE_REPO"
    git -C "$SOURCE_REPO" fetch origin "$SOURCE_COMMIT"
    if [ -d "$PINNED_SOURCE/.git" ] || [ -f "$PINNED_SOURCE/.git" ]; then
        current="$(git -C "$PINNED_SOURCE" rev-parse HEAD)"
        if [ "$current" != "$SOURCE_COMMIT" ]; then
            fail "existing pinned source is at $current, expected $SOURCE_COMMIT: $PINNED_SOURCE"
        fi
    else
        mkdir -p "$(dirname "$PINNED_SOURCE")"
        git -C "$SOURCE_REPO" worktree add --detach "$PINNED_SOURCE" "$SOURCE_COMMIT"
    fi
    git -C "$PINNED_SOURCE" submodule update --init --recursive
    current="$(git -C "$PINNED_SOURCE" rev-parse HEAD)"
    [ "$current" = "$SOURCE_COMMIT" ] || fail "pinned source mismatch: $current"
    log "pinned source=$PINNED_SOURCE commit=$current"
}

check_python() {
    command -v python3 >/dev/null || fail "python3 not found"
    python3 - <<'PY'
import importlib
import sys

required = [
    "coremltools",
    "numpy",
    "scipy",
    "sklearn",
    "onnx",
    "onnxruntime",
    "onnx2torch",
    "torch",
    "torchaudio",
    "hyperpyyaml",
    "librosa",
    "whisper",
]
modules = {}
missing = []
for name in required:
    try:
        modules[name] = importlib.import_module(name)
    except Exception as exc:
        missing.append((name, repr(exc)))
if missing:
    for name, error in missing:
        print(f"[PYTHON-MISSING] {name}: {error}")
    raise SystemExit(3)

if sys.version_info[:2] != (3, 11):
    print(f"[PYTHON-VERSION-MISMATCH] got={sys.version_info.major}.{sys.version_info.minor} expected=3.11")
    raise SystemExit(4)

expected = {
    "numpy": "1.26.4",
    "scipy": "1.17.1",
    "sklearn": "1.5.1",
    "onnx": "1.16.0",
    "onnxruntime": "1.18.0",
    "torch": "2.3.1",
    "torchaudio": "2.3.1",
    "whisper": "20231117",
}
actual = {
    "numpy": modules["numpy"].__version__,
    "scipy": modules["scipy"].__version__,
    "sklearn": modules["sklearn"].__version__,
    "onnx": modules["onnx"].__version__,
    "onnxruntime": modules["onnxruntime"].__version__,
    "torch": modules["torch"].__version__.split("+")[0],
    "torchaudio": modules["torchaudio"].__version__.split("+")[0],
    "whisper": modules["whisper"].__version__,
}
bad = {name: (actual[name], version) for name, version in expected.items() if actual[name] != version}
if bad:
    for name, (got, want) in bad.items():
        print(f"[PYTHON-VERSION-MISMATCH] {name}: got={got} expected={want}")
    raise SystemExit(4)

print("[PYTHON-DEPS] PASS")
print("[PYTHON-ABI] numpy=1.26.4 onnxruntime=1.18.0 scipy=1.17.1 sklearn=1.5.1")
PY
}

show_install_hint() {
    cat <<'EOF'
If the Python dependency/version check fails, repair the dedicated Python 3.11 environment:
  cd /Volumes/WD/Codes/Cosyvoice
  bash ios/tools/bootstrap_reference_env_macos.sh
  source "$HOME/.venvs/cosyvoice-reference-py311/bin/activate"
Then rerun this script. Do not install scikit-learn, NumPy, SciPy, ONNX Runtime, Torch, or Torchaudio individually; the lock file must be installed as a unit.
EOF
}

main() {
    command -v git >/dev/null || fail "git not found"
    command -v swift >/dev/null || fail "swift not found"
    command -v xcodebuild >/dev/null || fail "xcodebuild not found"

    prepare_publication
    prepare_pinned_source

    MODEL_DIR_RESOLVED="$(discover_model_dir || true)"
    [ -n "$MODEL_DIR_RESOLVED" ] || {
        show_install_hint
        fail "model directory not found. Run: export MODEL_DIR=/absolute/path/to/Fun-CosyVoice3-0.5B-2512"
    }
    MODEL_DIR="$(cd "$MODEL_DIR_RESOLVED" && pwd)"
    export MODEL_DIR

    require_file "$MODEL_DIR/speech_tokenizer_v3.onnx"
    require_file "$MODEL_DIR/campplus.onnx"
    require_file "$MODEL_DIR/flow.pt"
    require_file "$MODEL_DIR/cosyvoice3.yaml"
    [ -d "$MODEL_DIR/CosyVoice-BlankEN" ] || fail "missing model tokenizer/Qwen folder: $MODEL_DIR/CosyVoice-BlankEN"

    log "modelDir=$MODEL_DIR"
    if ! check_python; then
        show_install_hint
        exit 3
    fi

    if [ "$FORCE_REBUILD" = "1" ]; then
        log "force rebuild requested; clearing previous reference-release work"
        rm -rf "$COREML" "$PARITY"
    fi
    mkdir -p "$COREML" "$PARITY"

    cd "$PUBLICATION_ROOT/ios"

    if stage1_ready; then
        log "1/4 RESUME existing speech tokenizer + CAMPPlus Core ML candidates"
        python3 - "$COREML/reference_coreml_conversion.json" <<'PY'
import json
import sys
from pathlib import Path
value = json.loads(Path(sys.argv[1]).read_text())
print(json.dumps({
    "status": "RESUME_CONVERTED_REFERENCE_COREML",
    "speechTokenizer": value.get("speechTokenizer", {}).get("sha256"),
    "campPlus": value.get("campPlus", {}).get("sha256"),
}, indent=2))
PY
    else
        log "1/4 converting speech tokenizer + CAMPPlus to Core ML candidates"
        rm -rf "$COREML/speech-tokenizer-fixed605.mlpackage" \
               "$COREML/campplus-fixed604.mlpackage" \
               "$COREML/reference_coreml_conversion.json"
        python3 tools/convert_reference_onnx_to_coreml.py \
            --speech-tokenizer "$MODEL_DIR/speech_tokenizer_v3.onnx" \
            --campplus "$MODEL_DIR/campplus.onnx" \
            --output "$COREML"
    fi

    log "2/4 exporting dynamic per-reference Flow conditions"
    rm -rf "$COREML/flow-conditions-dynamic-151-302.mlpackage"
    python3 tools/export_dynamic_flow_conditions.py \
        --model-dir "$MODEL_DIR" \
        --output "$COREML/flow-conditions-dynamic-151-302.mlpackage" \
        --prompt-token-count 151 \
        --prompt-frame-count 302

    log "3/4 running Swift DSP + ONNX/CoreML + dynamic Flow parity"
    python3 tools/run_reference_release_gate.py \
        --source-root "$PINNED_SOURCE" \
        --model-dir "$MODEL_DIR" \
        --coreml-dir "$COREML" \
        --work "$PARITY"

    log "4/4 copying exact frontend tables beside the candidate reference assets"
    cp "$PARITY/fixture/whisper_mel_128.f32" "$COREML/"
    cp "$PARITY/fixture/kaldi_mel_80.f32" "$COREML/"
    cp "$PARITY/fixture/matcha_mel_80.f32" "$COREML/"
    cp "$PARITY/reference_host_parity_receipt.json" "$COREML/"

    python3 - <<PY
import json
from pathlib import Path
receipt = Path("$PARITY/reference_host_parity_receipt.json")
value = json.loads(receipt.read_text())
print(json.dumps(value, indent=2))
if value.get("status") != "PASS_HOST_PARITY":
    raise SystemExit(4)
print()
print("[COSYVOICE3-REFERENCE-MAC] HOST PARITY PASS")
print("[COSYVOICE3-REFERENCE-MAC] candidate assets: $COREML")
print("[COSYVOICE3-REFERENCE-MAC] host receipt:    $PARITY/reference_host_parity_receipt.json")
PY
}

main "$@"

# Code purpose: one-command generation and host parity validation for fixed225 custom-reference iOS assets.
# Upstream source: Ashtabula/CosyVoice3_NPU@878940245562bcd1dd0231d78157ba78d70b39f6.
# Model source: FunAudioLLM/Fun-CosyVoice3-0.5B-2512@29e01c4e8d000f4bcd70751be16fa94bf3d85a18.
# Runtime: macOS + Xcode + Swift + Python environment with pinned CosyVoice dependencies/coremltools/ONNX. Stage 1 resumes validated conversion outputs by default; set COSYVOICE3_FORCE_REBUILD=1 for a clean rebuild.
# Generated: 2026-10-02 America/New_York.
