#@title run_production_clean_room.sh
# Requirement: from a clean release checkout, fetch the immutable private RC through the ordinary SDK path, build/install an independent public-API-only consumer, retrieve physical-iPhone PCM evidence, and write a sanitized Production clean-room receipt.
#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; REPO="$(cd "$ROOT/.." && pwd)"; EXPECTED_BRANCH="${COSYVOICE3_RELEASE_BRANCH:-$(git -C "$REPO" branch --show-current)}"
PROJECT="$ROOT/validation/ProductionCleanRoom/CosyVoice3ProductionCleanRoom.xcodeproj"; SCHEME="CosyVoice3ProductionCleanRoom"; BUNDLE_ID="${COSYVOICE3_PRODUCTION_CLEANROOM_BUNDLE_ID:-com.actacomes.cosyvoice3.productioncleanroom}"
PYTHON="$ROOT/.venv-release/bin/python"; FETCHED="$ROOT/.work/production-clean-room/fetched-runtime"; GENERATED="$ROOT/validation/ProductionCleanRoom/GeneratedAssets"; RAW="$ROOT/.work/production-clean-room/device-receipt.json"; OUTPUT="$ROOT/validation/evidence/production_clean_room.json"; DERIVED="$ROOT/.work/ProductionCleanRoomDerivedData"; AUTO_REFERENCE="$ROOT/.work/production-clean-room/generated-reference"
main(){
    [ -n "${DEVICE_ID:-}" ] || { printf '[COSYVOICE3-PRODUCTION-CLEAN-ROOM] ERROR set DEVICE_ID\n'; return 2; }
    [ -n "${DEVELOPMENT_TEAM:-}" ] || { printf '[COSYVOICE3-PRODUCTION-CLEAN-ROOM] ERROR set DEVELOPMENT_TEAM\n'; return 2; }
    command -v git || return $?; command -v python3 || return $?; command -v xcodebuild || return $?; command -v xcrun || return $?
    if [ ! -f "${COSYVOICE3_REFERENCE_WAV:-}" ] || [ ! -s "${COSYVOICE3_REFERENCE_TRANSCRIPT:-}" ]; then
        command -v say || { printf '[COSYVOICE3-PRODUCTION-CLEAN-ROOM] ERROR no explicit reference and macOS say unavailable\n'; return 2; }
        command -v afconvert || { printf '[COSYVOICE3-PRODUCTION-CLEAN-ROOM] ERROR no explicit reference and afconvert unavailable\n'; return 2; }
        rm -rf "$AUTO_REFERENCE"; mkdir -p "$AUTO_REFERENCE"
        COSYVOICE3_REFERENCE_TRANSCRIPT="$AUTO_REFERENCE/reference.txt"
        COSYVOICE3_REFERENCE_WAV="$AUTO_REFERENCE/reference.wav"
        printf '%s\n' 'This is a clean room reference voice for CosyVoice3.' > "$COSYVOICE3_REFERENCE_TRANSCRIPT"
        say -v "${COSYVOICE3_CLEANROOM_SAY_VOICE:-Alex}" -o "$AUTO_REFERENCE/reference.aiff" "$(cat "$COSYVOICE3_REFERENCE_TRANSCRIPT")" || return $?
        afconvert -f WAVE -d LEI16@16000 -c 1 "$AUTO_REFERENCE/reference.aiff" "$COSYVOICE3_REFERENCE_WAV" || return $?
        printf '[COSYVOICE3-PRODUCTION-CLEAN-ROOM] generated transient reference with macOS say voice=%s wav=%s\n' "${COSYVOICE3_CLEANROOM_SAY_VOICE:-Alex}" "$COSYVOICE3_REFERENCE_WAV"
    else
        printf '[COSYVOICE3-PRODUCTION-CLEAN-ROOM] using explicit reference wav=%s transcript=%s\n' "$COSYVOICE3_REFERENCE_WAV" "$COSYVOICE3_REFERENCE_TRANSCRIPT"
    fi
    [ "$(git -C "$REPO" branch --show-current)" = "$EXPECTED_BRANCH" ] || { printf '[COSYVOICE3-PRODUCTION-CLEAN-ROOM] ERROR wrong branch\n'; return 2; }
    [ -z "$(git -C "$REPO" status --porcelain --untracked-files=no)" ] || { printf '[COSYVOICE3-PRODUCTION-CLEAN-ROOM] ERROR tracked worktree must be clean\n'; git -C "$REPO" status --short; return 2; }
    git -C "$REPO" pull --ff-only origin "$EXPECTED_BRANCH" || return $?
    python3 "$ROOT/validation/audit_production_clean_room.py" || return $?
    local candidate head
    candidate="$(python3 -c 'import json;print(json.load(open("'"$ROOT"'/validation/production_baseline.json"))["candidateReleaseHead"])')" || return $?
    git -C "$REPO" diff --quiet "$candidate" HEAD -- ios/Package.swift ios/Sources || { printf '[COSYVOICE3-PRODUCTION-CLEAN-ROOM] ERROR runtime source changed after frozen Candidate baseline; rerun Candidate validation\n'; return 3; }
    head="$(git -C "$REPO" rev-parse HEAD)" || return $?
    if [ ! -x "$PYTHON" ]; then python3 -m venv "$ROOT/.venv-release" || return $?; fi
    "$PYTHON" -m pip install -r "$ROOT/requirements-release.txt" || return $?
    "$PYTHON" - <<'PY' || return $?
from huggingface_hub import HfApi
x=HfApi().whoami(); n=(x.get("name") or x.get("fullname") or "") if isinstance(x,dict) else (getattr(x,"name","") or getattr(x,"fullname",""))
print("[COSYVOICE3-PRODUCTION-CLEAN-ROOM] HF identity="+repr(n),flush=True)
if n!="actacomes": raise SystemExit("Hugging Face login must be actacomes")
PY
    local profile version benchmark_receipt
    profile="$("$PYTHON" -c 'import json;print(json.load(open("'"$ROOT"'/validation/release_receipt.json"))["asset"]["profile"])')" || return $?
    version="$("$PYTHON" -c 'import json;print(json.load(open("'"$ROOT"'/validation/release_receipt.json"))["asset"]["version"])')" || return $?
    benchmark_receipt="$ROOT/validation/evidence/candidate_benchmark.json"
    case "$profile" in ios-dynamic-*) benchmark_receipt="$ROOT/validation/evidence/dynamic_candidate_benchmark.json";; esac
    [ -f "$benchmark_receipt" ] || { printf '[COSYVOICE3-PRODUCTION-CLEAN-ROOM] ERROR Candidate benchmark missing: %s\n' "$benchmark_receipt"; return 2; }
    printf '[COSYVOICE3-PRODUCTION-CLEAN-ROOM] asset=%s/%s benchmark=%s\n' "$profile" "$version" "$benchmark_receipt"
    rm -rf "$FETCHED" "$GENERATED" "$DERIVED"; mkdir -p "$GENERATED" "$(dirname "$RAW")" "$(dirname "$OUTPUT")"; : > "$GENERATED/.gitkeep"
    "$PYTHON" "$ROOT/assets/fetch_assets.py" --profile "$profile" --version "$version" --output "$FETCHED" --force || return $?
    "$PYTHON" "$ROOT/assets/validate_assets.py" --root "$FETCHED" --require-reference || return $?
    cp -R "$FETCHED" "$GENERATED/Runtime" || return $?; cp "$COSYVOICE3_REFERENCE_WAV" "$GENERATED/reference.wav" || return $?; cp "$COSYVOICE3_REFERENCE_TRANSCRIPT" "$GENERATED/reference.txt" || return $?
    "$PYTHON" - "$ROOT/validation/release_receipt.json" "$ROOT/validation/production_baseline.json" "$benchmark_receipt" "$GENERATED/production-clean-room-binding.json" "$head" "$COSYVOICE3_REFERENCE_TRANSCRIPT" "$COSYVOICE3_REFERENCE_WAV" <<'PY' || return $?
import json,sys
from pathlib import Path
release=json.loads(Path(sys.argv[1]).read_text()); base=json.loads(Path(sys.argv[2]).read_text()); bench=json.loads(Path(sys.argv[3]).read_text()); transcript=Path(sys.argv[6]).read_text().strip(); workload=bench["workload"]; text=workload["text"]
if bench.get("sourceCommit")!=base["validatedSourceCommit"] or bench.get("status")!="PASS": raise SystemExit("Candidate benchmark/baseline mismatch")
reference_wav=Path(sys.argv[6]).with_name("reference.wav") if Path(sys.argv[6]).name=="reference.txt" else None
# The staged host copies are authoritative; derive the WAV path beside the binding input only when appropriate.
reference_wav=Path(sys.argv[7])
a=release["asset"]; out={"schemaVersion":1,"releaseHead":sys.argv[5],"candidateReleaseHead":base["candidateReleaseHead"],"validatedSourceCommit":base["validatedSourceCommit"],"assetIdentity":release["assetIdentity"],"profile":a["profile"],"version":a["version"],"revision":a["revision"],"payloadTreeSha256":a["payloadTreeSha256"],"testedRuntimeTreeSha256":a["testedRuntimeTreeSha256"],"referenceTranscriptCharacters":len(transcript),"referenceWavSha256":__import__("hashlib").sha256(reference_wav.read_bytes()).hexdigest(),"workloadText":text,"workloadTextSha256":__import__("hashlib").sha256(text.encode()).hexdigest()}
Path(sys.argv[4]).write_text(json.dumps(out,indent=2,sort_keys=True)+"\n")
PY
    XCODE_ARGS=(-project "$PROJECT" -scheme "$SCHEME" -configuration Release -sdk iphoneos -destination "id=$DEVICE_ID" -derivedDataPath "$DERIVED" -allowProvisioningUpdates -allowProvisioningDeviceRegistration DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" CODE_SIGN_STYLE=Automatic)
    xcodebuild "${XCODE_ARGS[@]}" build || return $?
    SETTINGS="$(xcodebuild "${XCODE_ARGS[@]}" -showBuildSettings)" || return $?
    TARGET="$(printf '%s\n' "$SETTINGS" | awk '/Build settings for action build and target CosyVoice3ProductionCleanRoom:/{f=1;next} f&&/^[[:space:]]*TARGET_BUILD_DIR = /{sub(/^[[:space:]]*TARGET_BUILD_DIR = /,"");print;exit}')"
    WRAPPER="$(printf '%s\n' "$SETTINGS" | awk '/Build settings for action build and target CosyVoice3ProductionCleanRoom:/{f=1;next} f&&/^[[:space:]]*WRAPPER_NAME = /{sub(/^[[:space:]]*WRAPPER_NAME = /,"");print;exit}')"
    APP="$TARGET/$WRAPPER"; [ -d "$APP" ] || { printf '[COSYVOICE3-PRODUCTION-CLEAN-ROOM] ERROR app missing: %s\n' "$APP"; return 4; }
    xcrun devicectl device uninstall app --device "$DEVICE_ID" "$BUNDLE_ID" || true
    xcrun devicectl device install app --device "$DEVICE_ID" "$APP" || return $?
    xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID" || return $?
    rm -f "$RAW"
    for attempt in $(seq 1 36); do printf '[COSYVOICE3-PRODUCTION-CLEAN-ROOM] receipt poll %s/36\n' "$attempt"; if xcrun devicectl device copy from --device "$DEVICE_ID" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" --source "Documents/production-clean-room-receipt.json" --destination "$RAW"; then [ -s "$RAW" ] && break; fi; sleep 10; done
    [ -s "$RAW" ] || { printf '[COSYVOICE3-PRODUCTION-CLEAN-ROOM] ERROR receipt not produced\n'; return 5; }
    "$PYTHON" - "$RAW" <<'PY' || return $?
import json,sys
from pathlib import Path
x=json.loads(Path(sys.argv[1]).read_text())
print("[COSYVOICE3-PRODUCTION-CLEAN-ROOM] deviceReceipt="+json.dumps(x,sort_keys=True),flush=True)
if x.get("status")=="FAIL_PRODUCTION_CLEAN_ROOM": raise SystemExit(f"device clean-room failed phase={x.get('phase')} error={x.get('error')}")
PY
    "$PYTHON" - "$RAW" "$ROOT/validation/production_baseline.json" "$ROOT/validation/release_receipt.json" "$OUTPUT" <<'PY' || return $?
import json,sys,time
from pathlib import Path
raw=json.loads(Path(sys.argv[1]).read_text()); base=json.loads(Path(sys.argv[2]).read_text()); release=json.loads(Path(sys.argv[3]).read_text())
if raw.get("status")!="PASS_PRODUCTION_CLEAN_ROOM_PUBLIC_API_PCM" or raw.get("publicApiOnly") is not True: raise SystemExit("clean-room device status mismatch")
if raw.get("candidateReleaseHead")!=base["candidateReleaseHead"] or raw.get("validatedSourceCommit")!=base["validatedSourceCommit"] or raw.get("assetIdentity")!=release["assetIdentity"]: raise SystemExit("clean-room source/asset binding mismatch")
profile=(release.get("asset") or {}).get("profile","")
bench_name="dynamic_candidate_benchmark.json" if str(profile).startswith("ios-dynamic-") else "candidate_benchmark.json"
bench=json.loads((Path(sys.argv[3]).parent/"evidence"/bench_name).read_text()); expected=__import__("hashlib").sha256(bench["workload"]["text"].encode()).hexdigest()
if raw.get("workloadTextSha256")!=expected: raise SystemExit("clean-room workload differs from Candidate-frozen fixed225 workload")
if raw.get("sampleRate")!=24000 or raw.get("channels")!=1 or int(raw.get("samples",0))<=0 or raw.get("finite") is not True or raw.get("flowSteps")!=6: raise SystemExit("clean-room PCM/public-default contract mismatch")
profile=(release.get("asset") or {}).get("profile","")
if str(profile).startswith("ios-dynamic-"):
    bounds=release.get("speechTokenBounds")
    samples=int(raw["samples"])
    if bounds!=[1,479] or samples%960!=0 or not (bounds[0]<=samples//960<=bounds[1]): raise SystemExit("dynamic clean-room PCM length is outside validated 960*N / N1...479 contract")
out={"schemaVersion":1,"status":"PASS_PRODUCTION_CLEAN_ROOM","releaseHead":raw["releaseHead"],"candidateReleaseHead":raw["candidateReleaseHead"],"validatedSourceCommit":raw["validatedSourceCommit"],"assetIdentity":raw["assetIdentity"],"publicApiOnly":True,"flowSteps":6,"device":{"model":raw.get("device"),"modelIdentifier":raw.get("deviceModelIdentifier"),"systemName":raw.get("systemName"),"systemVersion":raw.get("systemVersion")},"pcm":{"sampleRate":24000,"channels":1,"samples":raw["samples"],"finite":True},"referenceWavSha256":raw.get("referenceWavSha256"),"workloadTextSha256":raw["workloadTextSha256"],"recordedAtUnix":int(time.time())}
Path(sys.argv[4]).write_text(json.dumps(out,indent=2,sort_keys=True)+"\n"); print("[COSYVOICE3-PRODUCTION-CLEAN-ROOM] PASS "+json.dumps(out,sort_keys=True),flush=True)
PY
    if [ -n "${ALL_SDK_ENTRY_RESULT_DIR:-}" ]; then
        mkdir -p "$ALL_SDK_ENTRY_RESULT_DIR"
        cp "$OUTPUT" "$ALL_SDK_ENTRY_RESULT_DIR/production_clean_room.json" || return $?
        cp "$ROOT/validation/release_receipt.json" "$ALL_SDK_ENTRY_RESULT_DIR/release_receipt.json" || return $?
        if [ -f "$ROOT/validation/evidence/dynamic_release_environment.json" ]; then
            cp "$ROOT/validation/evidence/dynamic_release_environment.json" "$ALL_SDK_ENTRY_RESULT_DIR/release_environment.json" || return $?
        fi
        printf '[COSYVOICE3-PRODUCTION-CLEAN-ROOM] exported all-SDK evidence=%s\n' "$ALL_SDK_ENTRY_RESULT_DIR"
    fi
}
main "$@"; RC=$?; printf '[COSYVOICE3-PRODUCTION-CLEAN-ROOM] rc=%s\n' "$RC"; test "$RC" -eq 0
# Code purpose: physical independent-consumer Production clean-room gate using only public CosyVoice3Core + ordinary immutable asset fetch.
# Runtime environment: macOS/Xcode, authenticated actacomes Hugging Face, connected trusted iPhone.
# Generated time: 2026-10-03 America/New_York.

# Changes 2026-10-03: print and fail immediately on a machine-readable device FAIL receipt instead of turning every app-side failure into a six-minute missing-file timeout.

# Changes 2026-10-03: stage the exact text from committed Candidate benchmark evidence and bind its SHA256 into the device/host receipt. This validates the frozen fixed225 lane without changing runtime behavior for early-EOS (<225-token) utterances.

# Changes 2026-10-04: resolve Candidate profile/version and benchmark from canonical release_receipt.json; support dynamic N1...479 960*N PCM while retaining historical fixed225 compatibility; release branch is overrideable/current rather than hard-coded.

# Changes 2026-10-04: when no explicit custom-reference fixture is supplied, generate a transient macOS say/afconvert speech reference under .work; hash-bind it into host/device receipts. No generated reference is committed, uploaded or included in public assets.

# Changes 2026-10-04: export sanitized clean-room/Candidate/environment receipts to ALL_SDK_ENTRY_RESULT_DIR before disposable all-SDK clone cleanup.
