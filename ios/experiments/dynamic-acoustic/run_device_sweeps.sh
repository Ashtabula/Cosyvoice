#!/bin/bash
set -euo pipefail

# Requirement: build/install DynamicAcousticProbe, auto-select an available physical iPhone, run native-RAS/acoustic sweeps in the foreground without attaching the app console, then return the shell prompt normally after completion.
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
EXP="$ROOT/ios/experiments/dynamic-acoustic"
PROJECT="$EXP/DeviceProbe/DynamicAcousticProbe.xcodeproj"
SCHEME="DynamicAcousticProbe"
BUNDLE_ID="com.actacomes.cosyvoice3.dynamicacoustic"
CONFIGURATION="Release"
RUNS="${RUNS:-32}"
NMIN="${NMIN:-151}"
NMAX="${NMAX:-225}"
RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)-$$}"
OUT="${OUT:-$EXP/evidence/device-sweeps-$RUN_ID}"
: "${DEVELOPMENT_TEAM:?export DEVELOPMENT_TEAM=<Apple-development-team-id>}"

mkdir -p "$OUT"
echo "===== VERIFY SOURCE ====="
git -C "$ROOT" rev-parse HEAD
git -C "$ROOT" status --short

echo "===== SELECT PHYSICAL IPHONE ====="
DESTINATIONS="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -showdestinations 2>&1)"
printf '%s\n' "$DESTINATIONS" | tee "$OUT/destinations.log"
if [[ -z "${DEVICE_ID:-}" ]] || [[ "$DEVICE_ID" == *"physical-iPhone-device-id"* ]] || ! printf '%s\n' "$DESTINATIONS" | grep -F "id:$DEVICE_ID" >/tmp/cosyvoice-device-match-$RUN_ID.txt; then
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

wait_receipt() {
  local remote="$1" local_path="$2" label="$3" attempt=0 tmp="$local_path.tmp" copy_log="$OUT/$label-copy.log"
  while true; do
    attempt=$((attempt+1))
    rm -f "$tmp"
    if xcrun devicectl device copy from --device "$DEVICE_ID" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" --source "Documents/$remote" --destination "$tmp" >"$copy_log" 2>&1; then
      if [[ -s "$tmp" ]]; then
        local status
        status="$(python3 - "$tmp" <<'PY'
import json,sys
try: print(json.load(open(sys.argv[1])).get("status",""))
except Exception: print("")
PY
)"
        if [[ -n "$status" && "$status" != "RUNNING" ]]; then
          mv "$tmp" "$local_path"
          echo "$label status=$status"
          python3 -m json.tool "$local_path"
          return 0
        fi
      fi
    fi
    if (( attempt % 15 == 0 )); then echo "$label waiting for unique receipt $remote"; fi
    sleep 2
  done
}

echo "===== LLM LENGTH SWEEP ====="
LLM_REMOTE="llm-length-sweep-$RUN_ID.json"
xcrun devicectl device process launch --device "$DEVICE_ID" --terminate-existing "$BUNDLE_ID" -- LLM_SWEEP "RUNS=$RUNS" "RUN_ID=$RUN_ID" | tee "$OUT/llm-sweep-launch.log"
wait_receipt "$LLM_REMOTE" "$OUT/$LLM_REMOTE" "llm-sweep"

echo "===== ACOUSTIC INTEGER-N SWEEP ====="
AC_REMOTE="dynamic-acoustic-shape-sweep-CPU_AND_NE-N$NMIN-$NMAX-$RUN_ID.json"
xcrun devicectl device process launch --device "$DEVICE_ID" --terminate-existing "$BUNDLE_ID" -- ACOUSTIC_SWEEP CPU_AND_NE "NMIN=$NMIN" "NMAX=$NMAX" "RUN_ID=$RUN_ID" | tee "$OUT/acoustic-sweep-launch.log"
wait_receipt "$AC_REMOTE" "$OUT/$AC_REMOTE" "acoustic-sweep"

echo "===== SUMMARY ====="
python3 - "$OUT/$LLM_REMOTE" "$OUT/$AC_REMOTE" <<'PY'
import json,sys
llm=json.load(open(sys.argv[1]));ac=json.load(open(sys.argv[2]))
print("LLM_STATUS",llm["status"])
print("LLM_SUMMARY",json.dumps(llm.get("summary",{}),sort_keys=True))
print("ACOUSTIC_STATUS",ac["status"])
print("ACOUSTIC_TESTS",len(ac.get("tests",[])))
print("ACOUSTIC_NEGATIVE_BOUNDARY_TESTS",json.dumps(ac.get("negativeBoundaryTests",[]),sort_keys=True))
if not str(llm["status"]).startswith(("PASS_","COMPLETE_")): raise SystemExit(1)
if ac["status"]!="PASS_EXHAUSTIVE_INTEGER_DYNAMIC_SHAPE_SWEEP_NOT_PROMOTED": raise SystemExit(1)
PY

echo "PASS receipts=$OUT"

# Code purpose: reproducibly run physical-iPhone LLM output-length and exhaustive dynamic-acoustic shape sweeps in the foreground; the Terminal remains usable after normal script completion.
# Upstream code/source: ios/experiments/dynamic-acoustic/DeviceProbe on experiment/ios-dynamic-acoustic; existing staged text-runtime and acoustic dynamic-family assets.
# Upstream purpose: prove native stochastic EOS-length distribution and every integer flexible-shape execution inside the exported N interval without production promotion.
# Runtime environment: macOS with Xcode/xcrun, signed physical iPhone, staged DeviceProbe assets.
# Generated time: 2026-10-04 America/New_York.
# Changes: auto-detect physical iPhone; treat placeholder DEVICE_ID as unset; avoid app-console attachment; keep the runner in the foreground; unique RUN_ID receipts prevent stale-result reuse.
