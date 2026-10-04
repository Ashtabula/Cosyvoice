#!/bin/bash
set -euo pipefail

# Requirement: build an isolated cap225-removed TextProbeRuntime, execute one deterministic physical-iPhone LLM state-capacity walk to the maximum existing 20x/512 policy target, persist every decode boundary, and return the Terminal on completion, failure, or stall.
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
EXP="$ROOT/ios/experiments/dynamic-acoustic"
PROJECT="$EXP/DeviceProbe/DynamicAcousticProbe.xcodeproj"
SCHEME="DynamicAcousticProbe"
BUNDLE_ID="com.actacomes.cosyvoice3.dynamicacoustic"
CONFIGURATION="Release"
LIBRARY="$ROOT/ios/.work/dynamic-acoustic/text-device-library-v2"
TEXT_ASSETS="$EXP/DeviceProbe/GeneratedAssets/text-runtime"
RUN_ID="${RUN_ID:-capacity512-$(date +%Y%m%d-%H%M%S)-$$}"
POLL_SECONDS="${POLL_SECONDS:-2}"
STALL_SECONDS="${STALL_SECONDS:-120}"
MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-3600}"
OUT="${OUT:-$EXP/evidence/llm-capacity-walk-$RUN_ID}"
: "${DEVELOPMENT_TEAM:?export DEVELOPMENT_TEAM=<Apple-development-team-id>}"

mkdir -p "$OUT"

echo "===== VERIFY SOURCE ====="
git -C "$ROOT" rev-parse HEAD
git -C "$ROOT" status --short

echo "===== PREPARE ISOLATED CAPACITY PROBE ====="
rm -rf "$LIBRARY"
python3 "$EXP/prepare_text_probe.py" --output "$LIBRARY" --library --llm-backend CPU_ONLY --remove-fixed225-cap | tee "$OUT/prepare-text-probe.log"
rm -rf "$TEXT_ASSETS"
python3 "$EXP/stage_text_runtime.py" --library "$LIBRARY" | tee "$OUT/stage-text-runtime.log"
python3 - "$TEXT_ASSETS/identity.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
lib=r["libraryIdentity"]
assert lib.get("fixed225CapRemoved") is True,lib
assert lib.get("generationPolicy")=="min(targetTextTokens*20,512-logicalPrefixLength)",lib
assert lib.get("llmBackend")=="CPU_ONLY",lib
print("LLM_CAPACITY_POLICY",lib["generationPolicy"])
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

echo "===== LLM STATE CAPACITY WALK ====="
REMOTE="llm-capacity-walk-$RUN_ID.json"
LOCAL="$OUT/$REMOTE"
TMP="$LOCAL.tmp"
COPY_LOG="$OUT/copy.log"
xcrun devicectl device process launch --device "$DEVICE_ID" --terminate-existing "$BUNDLE_ID" -- LLM_CAPACITY_WALK "RUN_ID=$RUN_ID" | tee "$OUT/launch.log"

start_epoch="$(date +%s)"
last_progress_key=""
last_change_epoch="$start_epoch"

while true; do
  rm -f "$TMP"
  if xcrun devicectl device copy from --device "$DEVICE_ID" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" --source "Documents/$REMOTE" --destination "$TMP" >"$COPY_LOG" 2>&1 && [[ -s "$TMP" ]]; then
    row="$(python3 - "$TMP" <<'PY'
import json,sys
try:
    r=json.load(open(sys.argv[1]))
    vals=[
        str(r.get("status","")),str(r.get("phase","")),
        str(r.get("decodeStep","")),str(r.get("absolutePosition","")),
        str(r.get("completedSpeechTokenCapacity","")),
        str(r.get("targetSpeechTokenCapacity","")),
        str(r.get("logicalPrefixLength","")),
        str(r.get("targetTextTokenCount",""))
    ]
    print("|".join(vals))
except Exception:
    print("|||||||")
PY
)"
    IFS='|' read -r status phase step position completed target prefix text_tokens <<<"$row"
    progress_key="$phase|$step|$completed"
    now_epoch="$(date +%s)"
    if [[ -n "$phase" && "$progress_key" != "$last_progress_key" ]]; then
      echo "LLM_CAPACITY_PROGRESS status=$status phase=$phase step=${step:-NA} position=${position:-NA} completed=${completed:-NA}/${target:-NA} prefix=${prefix:-NA} textTokens=${text_tokens:-NA}"
      last_progress_key="$progress_key"
      last_change_epoch="$now_epoch"
    fi
    if [[ -n "$status" && "$status" != "RUNNING" ]]; then
      mv "$TMP" "$LOCAL"
      echo "LLM_CAPACITY_STATUS=$status"
      break
    fi
    if (( now_epoch - last_change_epoch >= STALL_SECONDS )); then
      cp "$TMP" "$LOCAL"
      echo "ERROR: capacity walk made no durable progress for $STALL_SECONDS seconds"
      python3 -m json.tool "$LOCAL"
      exit 2
    fi
  fi

  now_epoch="$(date +%s)"
  if (( now_epoch - start_epoch >= MAX_WAIT_SECONDS )); then
    if [[ -s "$TMP" ]]; then cp "$TMP" "$LOCAL"; fi
    echo "ERROR: capacity walk exceeded total limit of $MAX_WAIT_SECONDS seconds"
    [[ -s "$LOCAL" ]] && python3 -m json.tool "$LOCAL"
    exit 3
  fi
  sleep "$POLL_SECONDS"
done

echo "===== SUMMARY ====="
python3 - "$LOCAL" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
for k in (
    "status","phase","contextCapacity","logicalPrefixLength","targetTextTokenCount",
    "minimumSpeechTokenCount","targetSpeechTokenCapacity",
    "completedSpeechTokenCapacity","decodeStep","absolutePosition","forcedSpeechToken"
):
    print(k,"=",r.get(k))
if r.get("status")!="PASS_LLM_STATE_CAPACITY_WALK_NOT_PROMOTED":
    raise SystemExit(1)
PY

echo "PASS receipt=$LOCAL"

# Code purpose: determine the physical stateful LLM runtime ceiling directly by walking every decode position to the maximum current upstream-policy target, with durable before/after decode receipts.
# Upstream source: isolated current CosyVoice3 SDK copy with only fixed225 policy cap removed; 20x policy, 512 KV state, model bytes and CPU_ONLY backend unchanged.
# Runtime environment: macOS Xcode/xcrun + signed physical iPhone; foreground only, live receipt polling, configurable stall and total limits.
# Generated time: 2026-10-04 America/New_York.
# Changes: dedicated deterministic capacity-only mode; no natural RAS/EOS claim, no acoustic execution, no shipping/release promotion.
