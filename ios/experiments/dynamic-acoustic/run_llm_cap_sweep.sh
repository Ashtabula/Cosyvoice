#!/bin/bash
set -euo pipefail

# Requirement: rebuild only the isolated TextProbeRuntime without the fixed225 generation cap, run the physical-iPhone native-RAS LLM length sweep, report live progress and cap source, then return the shell prompt normally. Frozen SDK/release sources and assets remain untouched.
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
EXP="$ROOT/ios/experiments/dynamic-acoustic"
PROJECT="$EXP/DeviceProbe/DynamicAcousticProbe.xcodeproj"
SCHEME="DynamicAcousticProbe"
BUNDLE_ID="com.actacomes.cosyvoice3.dynamicacoustic"
CONFIGURATION="Release"
LIBRARY="$ROOT/ios/.work/dynamic-acoustic/text-device-library-v2"
TEXT_ASSETS="$EXP/DeviceProbe/GeneratedAssets/text-runtime"
RUNS="${RUNS:-32}"
RUN_ID="${RUN_ID:-cap512-$(date +%Y%m%d-%H%M%S)-$$}"
POLL_SECONDS="${POLL_SECONDS:-10}"
MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-14400}"
OUT="${OUT:-$EXP/evidence/llm-cap-sweep-$RUN_ID}"
: "${DEVELOPMENT_TEAM:?export DEVELOPMENT_TEAM=<Apple-development-team-id>}"

mkdir -p "$OUT"
echo "===== VERIFY SOURCE ====="
git -C "$ROOT" rev-parse HEAD
git -C "$ROOT" status --short

echo "===== PREPARE ISOLATED LLM CAP PROBE ====="
rm -rf "$LIBRARY"
python3 "$EXP/prepare_text_probe.py" --output "$LIBRARY" --library --llm-backend CPU_ONLY --remove-fixed225-cap | tee "$OUT/prepare-text-probe.log"
rm -rf "$TEXT_ASSETS"
python3 "$EXP/stage_text_runtime.py" --library "$LIBRARY" | tee "$OUT/stage-text-runtime.log"
python3 - "$TEXT_ASSETS/identity.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
lib=r["libraryIdentity"]
assert lib.get("fixed225CapRemoved") is True, lib
assert lib.get("generationPolicy")=="min(targetTextTokens*20,512-logicalPrefixLength)", lib
assert lib.get("llmBackend")=="CPU_ONLY", lib
print("LLM_CAP_POLICY",lib["generationPolicy"])
print("LLM_BACKEND",lib["llmBackend"])
PY

echo "===== SELECT PHYSICAL IPHONE ====="
DESTINATIONS="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -showdestinations 2>&1)"
printf '%s\n' "$DESTINATIONS" | tee "$OUT/destinations.log"
if [[ -z "${DEVICE_ID:-}" ]] || [[ "$DEVICE_ID" == *"physical-iPhone-device-id"* ]] || ! printf '%s\n' "$DESTINATIONS" | grep -F "id:$DEVICE_ID" >"/tmp/cosyvoice-device-match-$RUN_ID.txt"; then
  DEVICE_ID="$(printf '%s\n' "$DESTINATIONS" | sed -n 's/.*{ platform:iOS, arch:arm64, id:\([^,}]*\), name:.*/\1/p' | head -n 1 | xargs)"
fi
if [[ -z "$DEVICE_ID" ]]; then
  echo "ERROR: no available physical iPhone found"
  exit 1
fi
echo "DEVICE_ID=$DEVICE_ID"

echo "===== BUILD ====="
BUILD_SETTINGS="$OUT/build-settings.txt"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIGURATION" -destination "id=$DEVICE_ID" DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" CODE_SIGN_STYLE=Automatic -showBuildSettings | tee "$BUILD_SETTINGS"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIGURATION" -destination "id=$DEVICE_ID" DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" CODE_SIGN_STYLE=Automatic build | tee "$OUT/build.log"
TARGET_BUILD_DIR="$(awk -F ' = ' '/^[[:space:]]*TARGET_BUILD_DIR = /{v=$2} END{print v}' "$BUILD_SETTINGS")"
FULL_PRODUCT_NAME="$(awk -F ' = ' '/^[[:space:]]*FULL_PRODUCT_NAME = /{v=$2} END{print v}' "$BUILD_SETTINGS")"
APP="$TARGET_BUILD_DIR/$FULL_PRODUCT_NAME"
test -d "$APP"
echo "APP=$APP"

echo "===== INSTALL ====="
xcrun devicectl device install app --device "$DEVICE_ID" "$APP" | tee "$OUT/install.log"

echo "===== LLM CAP SWEEP ====="
REMOTE="llm-length-sweep-$RUN_ID.json"
LOCAL="$OUT/$REMOTE"
TMP="$LOCAL.tmp"
COPY_LOG="$OUT/llm-cap-copy.log"
xcrun devicectl device process launch --device "$DEVICE_ID" --terminate-existing "$BUNDLE_ID" -- LLM_SWEEP "RUNS=$RUNS" "RUN_ID=$RUN_ID" | tee "$OUT/llm-cap-launch.log"

start_epoch="$(date +%s)"
last_done="-1"
while true; do
  rm -f "$TMP"
  if xcrun devicectl device copy from --device "$DEVICE_ID" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" --source "Documents/$REMOTE" --destination "$TMP" >"$COPY_LOG" 2>&1 && [[ -s "$TMP" ]]; then
    progress="$(python3 - "$TMP" "$RUNS" <<'PY'
import json,sys
try:
    r=json.load(open(sys.argv[1]))
    runs=r.get("runs",[])
    ok=[x for x in runs if x.get("status")=="PASS_RECORDED"]
    bad=[x for x in runs if x.get("status")!="PASS_RECORDED"]
    ns=[x.get("N") for x in ok if isinstance(x.get("N"),int)]
    caps=[x for x in ok if x.get("stopReason")=="MAX_LENGTH"]
    context=[x for x in caps if isinstance(x.get("logicalPrefixLength"),int) and x.get("maximumSpeechTokenCount")==512-x.get("logicalPrefixLength")]
    ratio=[x for x in caps if x not in context]
    zeros=[x for x in ok if x.get("N")==0]
    fields=[
        str(r.get("status","")),str(len(runs)),str(len(ok)),str(len(bad)),
        str(min(ns) if ns else ""),str(max(ns) if ns else ""),
        str(len(caps)),str(len(context)),str(len(ratio)),str(len(zeros)),str(r.get("phase",""))
    ]
    print("|".join(fields))
except Exception:
    print("|||||||||")
PY
)"
    IFS='|' read -r status done ok bad min_n max_n cap_hits context_hits ratio_hits zero_hits phase <<<"$progress"
    if [[ -n "${done:-}" && "$done" != "$last_done" ]]; then
      echo "LLM_CAP_PROGRESS done=$done/$((8*RUNS)) success=$ok failed=$bad minN=${min_n:-NA} maxN=${max_n:-NA} N0=$zero_hits maxLength=$cap_hits context512=$context_hits ratio20x=$ratio_hits phase=$phase"
      last_done="$done"
    fi
    if [[ -n "${status:-}" && "$status" != "RUNNING" ]]; then
      mv "$TMP" "$LOCAL"
      echo "LLM_CAP_STATUS=$status"
      break
    fi
  fi
  now_epoch="$(date +%s)"
  if (( now_epoch - start_epoch >= MAX_WAIT_SECONDS )); then
    if [[ -s "$TMP" ]]; then cp "$TMP" "$LOCAL"; fi
    echo "ERROR: LLM cap sweep timed out after $MAX_WAIT_SECONDS seconds"
    exit 1
  fi
  sleep "$POLL_SECONDS"
done

echo "===== SUMMARY ====="
python3 - "$LOCAL" <<'PY'
import collections,json,sys
r=json.load(open(sys.argv[1]))
runs=r.get("runs",[])
ok=[x for x in runs if x.get("status")=="PASS_RECORDED"]
bad=[x for x in runs if x.get("status")!="PASS_RECORDED"]
ns=[x["N"] for x in ok if isinstance(x.get("N"),int)]
caps=[x for x in ok if x.get("stopReason")=="MAX_LENGTH"]
context=[x for x in caps if isinstance(x.get("logicalPrefixLength"),int) and x.get("maximumSpeechTokenCount")==512-x.get("logicalPrefixLength")]
ratio=[x for x in caps if x not in context]
print("STATUS =",r.get("status"))
print("DONE =",len(runs))
print("SUCCESS =",len(ok))
print("FAILED =",len(bad))
print("N RANGE =", (min(ns),max(ns)) if ns else None)
print("STOP REASONS =",dict(collections.Counter(x.get("stopReason") for x in ok)))
print("MAX_LENGTH =",len(caps))
print("CONTEXT_512_HITS =",len(context))
print("UPSTREAM_20X_HITS =",len(ratio))
zeros=[x for x in ok if x.get("N")==0]
print("N0_RUNS =",len(zeros))
print("N0_RATE =",len(zeros)/len(ok) if ok else None)
for text_index in sorted({x.get("textIndex") for x in ok}):
    rows=[x for x in ok if x.get("textIndex")==text_index]
    values=[x["N"] for x in rows if isinstance(x.get("N"),int)]
    print("TEXT",text_index,"runs",len(rows),"minN",min(values) if values else None,"maxN",max(values) if values else None,
          "N0",sum(x.get("N")==0 for x in rows),
          "context512",sum(x in context for x in rows),"ratio20x",sum(x in ratio for x in rows))
if bad:
    print("FAILURES:")
    for x in bad: print(x)
if not str(r.get("status","")).startswith(("PASS_","COMPLETE_")): raise SystemExit(1)
PY

echo "PASS receipt=$LOCAL"

# Code purpose: measure the native stochastic LLM speech-token range after removing only the experiment copy's fixed225 cap, while retaining the upstream 20x policy and existing 512-position KV-state ceiling.
# Upstream source: current experiment/ios-dynamic-acoustic SDK copy generated by prepare_text_probe.py; production fixed225 source/assets remain untouched.
# Runtime environment: macOS Xcode/xcrun, signed physical iPhone, CPU_ONLY LLM backend, foreground runner with live durable-receipt progress.
# Generated time: 2026-10-04 America/New_York.
# Changes: dedicated cap sweep; explicit isolated-cap policy assertion; unique receipts; progress shows min/max and distinguishes 512-context from upstream-20x max-length hits; finite timeout; terminal prompt returns on completion or failure.

# Changes 2026-10-04: explicitly count/report native stochastic N0 observations overall and per text. This is evidence-only; EOS=6562 sampling and production SDK behavior remain unchanged.
