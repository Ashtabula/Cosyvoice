#!/bin/bash
set -euo pipefail

# Requirement: export/stage the full dynamic acoustic envelope N3...479, prove representative physical checkpoints first, then exhaustively sweep every integer N on a physical iPhone in resumable chunks. Per-request LLM cap remains dynamic: min(20x target text tokens, 512-logicalPrefixLength).
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
EXP="$ROOT/ios/experiments/dynamic-acoustic"
PYTHON="${COSYVOICE3_DYNAMIC_PYTHON:-$ROOT/ios/.work/dynamic-acoustic/venv/bin/python}"
PROJECT="$EXP/DeviceProbe/DynamicAcousticProbe.xcodeproj"
SCHEME="DynamicAcousticProbe"
BUNDLE_ID="com.actacomes.cosyvoice3.dynamicacoustic"
CONFIGURATION="Release"
BRANCH="experiment/ios-dynamic-acoustic"
CHECKPOINTS="${CHECKPOINTS:-3,225,256,320,384,448,479}"
CHUNK_SIZE="${CHUNK_SIZE:-32}"
RUN_ID="${RUN_ID:-n479-$(date +%Y%m%d-%H%M%S)-$$}"
OUT="${OUT:-$EXP/evidence/acoustic-n479-sweep-$RUN_ID}"
FAMILY="${COSYVOICE3_FULL_RANGE_FAMILY:-}"
POLL_SECONDS="${POLL_SECONDS:-5}"
STALL_SECONDS="${STALL_SECONDS:-1800}"
: "${DEVELOPMENT_TEAM:?export DEVELOPMENT_TEAM=<Apple-development-team-id>}"

mkdir -p "$OUT"

echo "===== VERIFY SOURCE ====="
[ "$(git -C "$ROOT" branch --show-current)" = "$BRANCH" ] || { echo "ERROR: switch to $BRANCH"; exit 2; }
git -C "$ROOT" rev-parse HEAD
git -C "$ROOT" status --short
[ -x "$PYTHON" ] || { echo "ERROR: missing dynamic Python $PYTHON"; exit 2; }

if [[ -z "$FAMILY" ]]; then
  for i in $(seq 1 99); do
    candidate="$ROOT/ios/.work/dynamic-acoustic/full-range-family-v$i"
    if [[ ! -e "$candidate" ]]; then FAMILY="$candidate"; break; fi
  done
fi
[[ -n "$FAMILY" && ! -e "$FAMILY" ]] || { echo "ERROR: fresh FAMILY path required: $FAMILY"; exit 2; }

echo "===== EXPORT FULL SYMBOLIC FAMILY N3...479 ====="
"$PYTHON" "$EXP/export_full_range_family.py" --output "$FAMILY" | tee "$OUT/export.log"
"$PYTHON" - "$FAMILY/receipt.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
assert r["status"]=="PASS_FULL_RANGE_SYMBOLIC_FAMILY_EXPORT_NOT_PROMOTED",r.get("status")
assert r["NBounds"]==[3,479],r.get("NBounds")
assert r["TBounds"]==[308,1260],r.get("TBounds")
assert r["GBounds"]==[6,958],r.get("GBounds")
print("FAMILY_STATUS",r["status"])
print("N_BOUNDS",r["NBounds"],"T_BOUNDS",r["TBounds"],"G_BOUNDS",r["GBounds"])
print("GENERATION_CONTRACT",r["generationContract"])
PY

echo "===== STAGE FULL-RANGE DEVICE ASSETS ====="
rm -rf "$EXP/DeviceProbe/GeneratedAssets/acoustic"
"$PYTHON" "$EXP/stage_full_range_probe.py" --family "$FAMILY" | tee "$OUT/stage.log"

echo "===== ENSURE LOCAL PROBE PACKAGE ====="
LIBRARY="$ROOT/ios/.work/dynamic-acoustic/text-device-library-v2"
if [[ ! -f "$LIBRARY/Package.swift" ]]; then
  rm -rf "$LIBRARY"
  python3 "$EXP/prepare_text_probe.py" --output "$LIBRARY" --library --llm-backend CPU_ONLY --remove-fixed225-cap | tee "$OUT/prepare-probe-library.log"
fi

echo "===== SELECT PHYSICAL IPHONE ====="
DESTINATIONS="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -showdestinations 2>&1)"
printf '%s\n' "$DESTINATIONS" | tee "$OUT/destinations.log"
if [[ -z "${DEVICE_ID:-}" ]] || [[ "$DEVICE_ID" == *"physical-iPhone-device-id"* ]] || ! printf '%s\n' "$DESTINATIONS" | grep -F "id:$DEVICE_ID" >"/tmp/cosyvoice-device-match-$RUN_ID.txt"; then
  DEVICE_ID="$(printf '%s\n' "$DESTINATIONS" | sed -n 's/.*{ platform:iOS, arch:arm64, id:\([^,}]*\), name:.*/\1/p' | head -n 1 | xargs)"
fi
[[ -n "$DEVICE_ID" ]] || { echo "ERROR: no available physical iPhone"; exit 2; }
echo "DEVICE_ID=$DEVICE_ID"

echo "===== BUILD ====="
BUILD_SETTINGS="$OUT/build-settings.txt"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIGURATION" -destination "id=$DEVICE_ID" DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" CODE_SIGN_STYLE=Automatic -showBuildSettings | tee "$BUILD_SETTINGS"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIGURATION" -destination "id=$DEVICE_ID" DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" CODE_SIGN_STYLE=Automatic build | tee "$OUT/build.log"
TARGET_BUILD_DIR="$(awk -F ' = ' '/^[[:space:]]*TARGET_BUILD_DIR = /{v=$2} END{print v}' "$BUILD_SETTINGS")"
FULL_PRODUCT_NAME="$(awk -F ' = ' '/^[[:space:]]*FULL_PRODUCT_NAME = /{v=$2} END{print v}' "$BUILD_SETTINGS")"
APP="$TARGET_BUILD_DIR/$FULL_PRODUCT_NAME"
test -d "$APP"

echo "===== INSTALL ====="
xcrun devicectl device install app --device "$DEVICE_ID" "$APP" | tee "$OUT/install.log"

wait_receipt() {
  local remote="$1"
  local local_path="$2"
  local label="$3"
  local tmp="$local_path.tmp"
  local copy_log="$OUT/$label-copy.log"
  local last_key=""
  local last_change
  last_change="$(date +%s)"
  while true; do
    rm -f "$tmp"
    if xcrun devicectl device copy from --device "$DEVICE_ID" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" --source "Documents/$remote" --destination "$tmp" >"$copy_log" 2>&1 && [[ -s "$tmp" ]]; then
      row="$(python3 - "$tmp" <<'PY'
import json,sys
try:
 r=json.load(open(sys.argv[1]));tests=r.get("tests",[]);last=tests[-1] if tests else {}
 print("|".join(map(str,[r.get("status",""),r.get("phase",""),len(tests),last.get("N",""),last.get("status","")])))
except Exception: print("||||")
PY
)"
      IFS='|' read -r status phase count last_n last_status <<<"$row"
      key="$phase|$count|$last_n|$last_status"
      now="$(date +%s)"
      if [[ -n "$phase" && "$key" != "$last_key" ]]; then
        echo "$label progress phase=$phase tests=$count lastN=${last_n:-NA} lastStatus=${last_status:-NA}"
        last_key="$key";last_change="$now"
      fi
      if [[ -n "$status" && "$status" != "RUNNING" ]]; then
        mv "$tmp" "$local_path"
        echo "$label status=$status"
        [[ "$status" == "PASS_EXHAUSTIVE_INTEGER_DYNAMIC_SHAPE_SWEEP_NOT_PROMOTED" ]] || { python3 -m json.tool "$local_path"; return 1; }
        return 0
      fi
      if (( now-last_change >= STALL_SECONDS )); then
        cp "$tmp" "$local_path"
        echo "ERROR: $label no durable progress for $STALL_SECONDS seconds"
        python3 -m json.tool "$local_path"
        return 2
      fi
    fi
    sleep "$POLL_SECONDS"
  done
}

echo "===== CHECKPOINT SWEEP ====="
CHECK_RUN="$RUN_ID-checkpoints"
CHECK_REMOTE="dynamic-acoustic-shape-sweep-CPU_AND_NE-values-$CHECK_RUN.json"
xcrun devicectl device process launch --device "$DEVICE_ID" --terminate-existing "$BUNDLE_ID" -- ACOUSTIC_SWEEP CPU_AND_NE "NVALUES=$CHECKPOINTS" "RUN_ID=$CHECK_RUN" | tee "$OUT/checkpoints-launch.log"
wait_receipt "$CHECK_REMOTE" "$OUT/$CHECK_REMOTE" "checkpoints"

echo "===== EXHAUSTIVE INTEGER SWEEP N3...479 ====="
mkdir -p "$OUT/chunks"
start=3
while (( start <= 479 )); do
  end=$((start+CHUNK_SIZE-1))
  (( end > 479 )) && end=479
  chunk_run="$RUN_ID-N$start-$end"
  remote="dynamic-acoustic-shape-sweep-CPU_AND_NE-N$start-$end-$chunk_run.json"
  local_path="$OUT/chunks/$remote"
  echo "----- CHUNK N$start...N$end -----"
  xcrun devicectl device process launch --device "$DEVICE_ID" --terminate-existing "$BUNDLE_ID" -- ACOUSTIC_SWEEP CPU_AND_NE "NMIN=$start" "NMAX=$end" "RUN_ID=$chunk_run" | tee "$OUT/chunks/N$start-$end-launch.log"
  wait_receipt "$remote" "$local_path" "N$start-$end"
  start=$((end+1))
done

echo "===== AGGREGATE ====="
python3 - "$OUT/$CHECK_REMOTE" "$OUT/chunks" <<'PY'
import json,pathlib,sys
check=json.load(open(sys.argv[1]));folder=pathlib.Path(sys.argv[2])
rows=[]
for p in sorted(folder.glob("dynamic-acoustic-shape-sweep-CPU_AND_NE-N*.json")):
 r=json.load(open(p))
 if r.get("status")!="PASS_EXHAUSTIVE_INTEGER_DYNAMIC_SHAPE_SWEEP_NOT_PROMOTED":
  raise SystemExit(f"failed receipt {p}: {r.get('status')}")
 rows.extend(r.get("tests",[]))
ns=sorted(x["N"] for x in rows if x.get("status")=="PASS_SHAPE_EXECUTION")
expected=list(range(3,480))
print("CHECKPOINTS",[(x.get("N"),x.get("status")) for x in check.get("tests",[])])
print("INTEGER_TESTS",len(ns))
print("N_RANGE",(min(ns),max(ns)) if ns else None)
missing=sorted(set(expected)-set(ns));duplicates=len(ns)-len(set(ns))
print("MISSING",missing)
print("DUPLICATES",duplicates)
if ns!=expected: raise SystemExit("full integer coverage mismatch")
negative=check.get("negativeBoundaryTests",[])
print("NEGATIVE_BOUNDARIES",negative)
if len(negative)!=2 or not all(x.get("status")=="PASS_REJECTED_OUT_OF_RANGE" for x in negative):
 raise SystemExit("boundary rejection proof missing")
print("PASS_FULL_N3_TO_N479_INTEGER_SWEEP")
PY

echo "PASS evidence=$OUT"
echo "FAMILY=$FAMILY"

# Code purpose: re-export the global dynamic acoustic envelope implied by the fixed512 LLM, then physical-checkpoint and exhaustively execute every integer N=3...479 in resumable chunks.
# Upstream source: experiment/ios-dynamic-acoustic; fixed512 LLM capacity proof N479; per-request cap remains min(20x target text tokens,512-logicalPrefixLength).
# Runtime environment: macOS arm64 dynamic Python venv, Xcode/coremlcompiler, signed physical iPhone.
# Generated time: 2026-10-04 America/New_York.
# Changes: full-range exporter/stager, discrete checkpoint gate, exact-shape synthetic device inputs, chunked exhaustive sweep, negative N2/N480 boundary proof; no frozen release or production promotion.
