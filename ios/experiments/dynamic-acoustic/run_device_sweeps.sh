#!/bin/bash
set -euo pipefail

# Requirement: build/install the existing DynamicAcousticProbe, run native-RAS LLM length sweep and exhaustive dynamic acoustic integer-N sweep, then retrieve durable receipts without modifying shipping SDK/assets.
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
EXP="$ROOT/ios/experiments/dynamic-acoustic"
PROJECT="$EXP/DeviceProbe/DynamicAcousticProbe.xcodeproj"
SCHEME="DynamicAcousticProbe"
BUNDLE_ID="com.actacomes.cosyvoice3.dynamicacoustic"
CONFIGURATION="Release"
RUNS="${RUNS:-32}"
NMIN="${NMIN:-151}"
NMAX="${NMAX:-225}"
OUT="${OUT:-$EXP/evidence/device-sweeps-$(date +%Y%m%d-%H%M%S)}"
: "${DEVICE_ID:?export DEVICE_ID=<physical-iPhone-device-id>}"
: "${DEVELOPMENT_TEAM:?export DEVELOPMENT_TEAM=<Apple-development-team-id>}"
mkdir -p "$OUT"

echo "===== VERIFY SOURCE ====="
git -C "$ROOT" rev-parse HEAD
git -C "$ROOT" status --short

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

pull_receipt() {
  local remote="$1" local_path="$2"
  rm -f "$local_path"
  xcrun devicectl device copy from --device "$DEVICE_ID" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" --source "Documents/$remote" --destination "$local_path"
  test -s "$local_path"
  python3 -m json.tool "$local_path"
}

echo "===== LLM LENGTH SWEEP ====="
xcrun devicectl device process launch --device "$DEVICE_ID" --terminate-existing --console "$BUNDLE_ID" -- LLM_SWEEP "RUNS=$RUNS" | tee "$OUT/llm-sweep-console.log"
pull_receipt "llm-length-sweep.json" "$OUT/llm-length-sweep.json"

echo "===== ACOUSTIC INTEGER-N SWEEP ====="
xcrun devicectl device process launch --device "$DEVICE_ID" --terminate-existing --console "$BUNDLE_ID" -- ACOUSTIC_SWEEP CPU_AND_NE "NMIN=$NMIN" "NMAX=$NMAX" | tee "$OUT/acoustic-sweep-console.log"
pull_receipt "dynamic-acoustic-shape-sweep-CPU_AND_NE-N$NMIN-$NMAX.json" "$OUT/dynamic-acoustic-shape-sweep-CPU_AND_NE-N$NMIN-$NMAX.json"

echo "===== SUMMARY ====="
python3 - "$OUT/llm-length-sweep.json" "$OUT/dynamic-acoustic-shape-sweep-CPU_AND_NE-N$NMIN-$NMAX.json" <<'PY'
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

# Code purpose: reproducibly execute physical-iPhone LLM output-length and exhaustive dynamic-acoustic shape sweeps and retrieve machine-readable receipts.
# Upstream code/source: ios/experiments/dynamic-acoustic/DeviceProbe on experiment/ios-dynamic-acoustic; existing staged text-runtime and acoustic dynamic-family assets.
# Upstream purpose: prove native stochastic EOS-length distribution and every integer flexible-shape execution inside the exported N interval without production promotion.
# Runtime environment: macOS with Xcode/xcrun, signed physical iPhone, staged DeviceProbe assets.
# Generated time: 2026-10-04 America/New_York.
# Changes: new file, all lines; no shipping SDK/runtime/asset modification.
