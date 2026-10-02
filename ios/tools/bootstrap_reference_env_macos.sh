#@title bootstrap_reference_env_macos.sh
# Requirement: create the minimal isolated Python 3.11 environment required by the CosyVoice3 iOS reference-asset conversion/parity pipeline while preserving all dependency diagnostics.
#!/usr/bin/env bash
set -u
ROOT="${COSYVOICE3_PUBLICATION_ROOT:-/Volumes/WD/Codes/Cosyvoice}"
VENV="${COSYVOICE3_REFERENCE_VENV:-$HOME/.venvs/cosyvoice-reference-py311}"
REQ="$ROOT/ios/tools/reference-requirements-macos.txt"
log(){ printf '[COSYVOICE3-PYENV] %s\n' "$*"; }
fail(){ printf '[COSYVOICE3-PYENV] ERROR %s\n' "$1"; return 1; }
main(){
    [ -f "$REQ" ] || { fail "requirements file missing: $REQ"; return 2; }
    local python="" resolved="" existing=""
    for candidate in python3.11 /opt/homebrew/bin/python3.11 /usr/local/bin/python3.11; do
        if resolved="$(command -v "$candidate")"; then python="$resolved"; break; fi
    done
    if [ -z "$python" ]; then
        cat <<'EOF'
Python 3.11 was not found.
Install with Homebrew:
  brew install python@3.11
Then rerun the bootstrap script.
EOF
        return 3
    fi
    log "python=$python"; "$python" --version || return $?
    mkdir -p "$(dirname "$VENV")" || return $?
    if [ -d "$VENV" ]; then
        [ -x "$VENV/bin/python" ] || { fail "existing venv has no Python executable: $VENV"; return 2; }
        existing="$("$VENV/bin/python" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')" || return $?
        [ "$existing" = "3.11" ] || { fail "existing venv uses Python $existing, expected 3.11: $VENV"; return 2; }
        log "reusing venv=$VENV"
    else
        log "creating venv=$VENV"; "$python" -m venv "$VENV" || return $?
    fi
    local py="$VENV/bin/python" pip="$VENV/bin/pip"
    "$py" -m pip install --upgrade "pip<26" "setuptools==80.9.0" wheel || return $?
    log "installing binary/runtime dependencies"; "$pip" install --upgrade --force-reinstall -r "$REQ" || return $?
    log "installing OpenAI Whisper 20231117 without build isolation"; "$pip" install --no-build-isolation --no-cache-dir --constraint "$REQ" "openai-whisper==20231117" || return $?
    log "verifying SciPy/dyld first"
    "$py" - <<'PY'
import scipy,scipy.sparse.linalg
print("[SCIPY-DYLD] PASS",scipy.__version__)
PY
    [ $? -eq 0 ] || return $?
    log "verifying Whisper packaging compatibility"
    "$py" - <<'PY'
import pkg_resources,whisper
print("[WHISPER-BUILD] PASS",whisper.__version__)
PY
    [ $? -eq 0 ] || return $?
    log "verifying conversion/parity imports and exact ABI-sensitive versions"
    "$py" - <<'PY'
import coremltools,hyperpyyaml,librosa,numpy,onnx,onnx2torch,onnxruntime,scipy,sklearn,soundfile,torch,torchaudio,whisper
expected={"numpy":"1.26.4","scipy":"1.17.1","sklearn":"1.5.1","onnx":"1.16.0","onnxruntime":"1.18.0","torch":"2.3.1","torchaudio":"2.3.1","whisper":"20231117"}
actual={"numpy":numpy.__version__,"scipy":scipy.__version__,"sklearn":sklearn.__version__,"onnx":onnx.__version__,"onnxruntime":onnxruntime.__version__,"torch":torch.__version__.split("+")[0],"torchaudio":torchaudio.__version__.split("+")[0],"whisper":whisper.__version__}
bad={name:(actual[name],version) for name,version in expected.items() if actual[name]!=version}
if bad:
    for name,(got,want) in bad.items(): print(f"[VERSION-MISMATCH] {name}: got={got} expected={want}")
    raise SystemExit(4)
print("[COSYVOICE3-PYENV] PASS"); print("coremltools",coremltools.__version__)
for name in ("numpy","scipy","sklearn","onnx","onnxruntime","torch","torchaudio","whisper"): print(name,actual[name])
PY
    [ $? -eq 0 ] || return $?
    cat <<EOF
[COSYVOICE3-PYENV] READY
venv=$VENV
python=$py
EOF
}
main "$@"
RC=$?
printf '[COSYVOICE3-PYENV] rc=%s\n' "$RC"
test "$RC" -eq 0
# Code purpose: isolated macOS Python 3.11 environment for reference-model conversion/parity with exact ABI-sensitive package verification and no suppressed diagnostics.
# Upstream package pins: CosyVoice3_NPU requirements at 878940245562bcd1dd0231d78157ba78d70b39f6 plus the reference release lock.
# Runtime: macOS, Python 3.11.
# Generated: 2026-10-02 America/New_York.
# Changes 2026-10-02: converted historical exit/set-e behavior to main()/return status propagation, removed stderr suppression and quiet command probes, retained all package-install/import/version diagnostics, and preserved the existing environment contract.
