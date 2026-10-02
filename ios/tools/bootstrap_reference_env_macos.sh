#!/usr/bin/env bash
# bootstrap_reference_env_macos.sh
# Requirement: create the minimal isolated Python 3.11 environment required by the CosyVoice3 iOS reference-asset conversion/parity pipeline.
set -euo pipefail

ROOT="${COSYVOICE3_PUBLICATION_ROOT:-/Volumes/WD/Codes/Cosyvoice}"
VENV="${COSYVOICE3_REFERENCE_VENV:-$HOME/.venvs/cosyvoice-reference-py311}"
REQ="$ROOT/ios/tools/reference-requirements-macos.txt"

log() { printf '[COSYVOICE3-PYENV] %s\n' "$*"; }
fail() { printf '[COSYVOICE3-PYENV] ERROR %s\n' "$*" >&2; exit 2; }

[ -f "$REQ" ] || fail "requirements file missing: $REQ"

PYTHON=""
for candidate in python3.11 /opt/homebrew/bin/python3.11 /usr/local/bin/python3.11; do
    if command -v "$candidate" >/dev/null 2>&1; then
        PYTHON="$(command -v "$candidate")"
        break
    fi
done

if [ -z "$PYTHON" ]; then
    cat <<'EOF'
Python 3.11 was not found.

Install with Homebrew:
  brew install python@3.11

Then rerun:
  bash /Volumes/WD/Codes/Cosyvoice/ios/tools/bootstrap_reference_env_macos.sh
EOF
    exit 3
fi

log "python=$PYTHON"
"$PYTHON" --version

mkdir -p "$(dirname "$VENV")"

if [ -d "$VENV" ]; then
    existing="$("$VENV/bin/python" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || true)"
    if [ "$existing" != "3.11" ]; then
        fail "existing venv uses Python $existing, expected 3.11: $VENV"
    fi
    log "reusing venv=$VENV"
else
    log "creating venv=$VENV"
    "$PYTHON" -m venv "$VENV"
fi

PY="$VENV/bin/python"
PIP="$VENV/bin/pip"

# openai-whisper==20231117 setup.py imports pkg_resources during metadata/build.
# New isolated setuptools environments can omit that import path, so keep one
# known-compatible setuptools in the real venv and install Whisper without PEP517 isolation.
"$PY" -m pip install --upgrade "pip<26" "setuptools==80.9.0" wheel

log "installing binary/runtime dependencies"
"$PIP" install --upgrade --force-reinstall -r "$REQ"

log "installing OpenAI Whisper 20231117 without build isolation"
"$PIP" install --no-build-isolation --no-cache-dir --constraint "$REQ" "openai-whisper==20231117"

log "verifying SciPy/dyld first"
"$PY" - <<'PY'
import scipy
import scipy.sparse.linalg
print("[SCIPY-DYLD] PASS", scipy.__version__)
PY

log "verifying Whisper packaging compatibility"
"$PY" - <<'PY'
import pkg_resources
import whisper
print("[WHISPER-BUILD] PASS", whisper.__version__)
PY

log "verifying conversion/parity imports and exact ABI-sensitive versions"
"$PY" - <<'PY'
import coremltools
import hyperpyyaml
import librosa
import numpy
import onnx
import onnx2torch
import onnxruntime
import scipy
import sklearn
import soundfile
import torch
import torchaudio
import whisper

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
    "numpy": numpy.__version__,
    "scipy": scipy.__version__,
    "sklearn": sklearn.__version__,
    "onnx": onnx.__version__,
    "onnxruntime": onnxruntime.__version__,
    "torch": torch.__version__.split("+")[0],
    "torchaudio": torchaudio.__version__.split("+")[0],
    "whisper": whisper.__version__,
}
bad = {name: (actual[name], version) for name, version in expected.items() if actual[name] != version}
if bad:
    for name, (got, want) in bad.items():
        print(f"[VERSION-MISMATCH] {name}: got={got} expected={want}")
    raise SystemExit(4)

print("[COSYVOICE3-PYENV] PASS")
print("coremltools", coremltools.__version__)
for name in ("numpy", "scipy", "sklearn", "onnx", "onnxruntime", "torch", "torchaudio", "whisper"):
    print(name, actual[name])
PY

cat <<EOF

[COSYVOICE3-PYENV] READY

Run:
  source "$VENV/bin/activate"
  cd "$ROOT"
  bash ios/tools/run_reference_release_mac.sh

Or without activation:
  PATH="$VENV/bin:\$PATH" bash "$ROOT/ios/tools/run_reference_release_mac.sh"

The old Python 3.10 venv under:
  $ROOT/ios/.venv-reference
is no longer used.
EOF

# Code purpose: isolated macOS Python 3.11 environment avoiding the older SciPy PROPACK Mach-O loader failure and Whisper 20231117 pkg_resources build-isolation failure.
# Upstream package pins: CosyVoice3_NPU requirements at 878940245562bcd1dd0231d78157ba78d70b39f6, with SciPy raised to 1.17.1 for the newer PROPACK implementation.
# Runtime: macOS, Python 3.11. ABI-sensitive NumPy/SciPy/scikit-learn/ONNX Runtime versions are verified exactly and Whisper installation is constrained by the same lock file.
# Generated: 2026-10-02 America/New_York.
