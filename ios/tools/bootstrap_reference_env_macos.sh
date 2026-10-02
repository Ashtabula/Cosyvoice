#!/usr/bin/env bash
# bootstrap_reference_env_macos.sh
# Requirement: create the minimal isolated Python 3.10 environment required by the CosyVoice3 iOS reference-asset conversion/parity pipeline.
set -euo pipefail

ROOT="${COSYVOICE3_PUBLICATION_ROOT:-/Volumes/WD/Codes/Cosyvoice}"
VENV="${COSYVOICE3_REFERENCE_VENV:-$ROOT/ios/.venv-reference}"
REQ="$ROOT/ios/tools/reference-requirements-macos.txt"

log() { printf '[COSYVOICE3-PYENV] %s\n' "$*"; }
fail() { printf '[COSYVOICE3-PYENV] ERROR %s\n' "$*" >&2; exit 2; }

if [ ! -f "$REQ" ]; then
    fail "requirements file missing: $REQ"
fi

PYTHON=""
for candidate in python3.10 /opt/homebrew/bin/python3.10 /usr/local/bin/python3.10; do
    if command -v "$candidate" >/dev/null 2>&1; then
        PYTHON="$(command -v "$candidate")"
        break
    fi
done

if [ -z "$PYTHON" ]; then
    cat <<'EOF'
Python 3.10 was not found.

If Homebrew is installed:
  brew install python@3.10

Then rerun:
  bash /Volumes/WD/Codes/Cosyvoice/ios/tools/bootstrap_reference_env_macos.sh
EOF
    exit 3
fi

log "python=$PYTHON"
"$PYTHON" --version

if [ ! -d "$VENV" ]; then
    log "creating venv=$VENV"
    "$PYTHON" -m venv "$VENV"
else
    log "reusing venv=$VENV"
fi

PY="$VENV/bin/python"
PIP="$VENV/bin/pip"

"$PY" -m pip install --upgrade pip setuptools wheel
"$PIP" install -r "$REQ"

log "verifying imports"
"$PY" - <<'PY'
import coremltools
import hyperpyyaml
import librosa
import numpy
import onnx
import onnx2torch
import onnxruntime
import soundfile
import torch
import torchaudio
import whisper

print("[COSYVOICE3-PYENV] PASS")
print("python import set complete")
print("coremltools", coremltools.__version__)
print("numpy", numpy.__version__)
print("onnx", onnx.__version__)
print("onnxruntime", onnxruntime.__version__)
print("torch", torch.__version__)
print("torchaudio", torchaudio.__version__)
PY

cat <<EOF

[COSYVOICE3-PYENV] READY

Run:
  source "$VENV/bin/activate"
  cd "$ROOT"
  bash ios/tools/run_reference_release_mac.sh

Or without activating:
  PATH="$VENV/bin:\$PATH" bash "$ROOT/ios/tools/run_reference_release_mac.sh"
EOF

# Code purpose: isolated minimal macOS conversion/parity environment for CosyVoice3 iOS reference assets.
# Upstream package pins: CosyVoice3_NPU requirements at 878940245562bcd1dd0231d78157ba78d70b39f6.
# Runtime: macOS, Python 3.10.
# Generated: 2026-10-02 America/New_York.
