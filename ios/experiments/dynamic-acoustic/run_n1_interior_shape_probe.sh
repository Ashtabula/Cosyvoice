#!/bin/bash
set -euo pipefail

# Requirement: isolate the exact interior dynamic-acoustic shape that stalled in N1 public-API smoke. Stage the physically lower-bound-approved N1...479 family, run only the requested N values through the existing physical AcousticShapeSweepProbe using CPU_AND_NE plus reshapeFrequency=.infrequent, preserve a durable receipt, then uninstall the probe to return device storage for DeviceSmoke.
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
EXP="$ROOT/ios/experiments/dynamic-acoustic"
PYTHON="${COSYVOICE3_DYNAMIC_PYTHON:-$ROOT/ios/.work/dynamic-acoustic/venv/bin/python}"
PROJECT="$EXP/DeviceProbe/DynamicAcousticProbe.xcodeproj"
SCHEME="DynamicAcousticProbe"
BUNDLE_ID="com.actacomes.cosyvoice3.dynamicacoustic"
DEVICE_SMOKE_BUNDLE="com.actacomes.cosyvoice3.devicesmoke"
CONFIGURATION="Release"
BRANCH="experiment/ios-dynamic-acoustic"
NVALUES="${NVALUES:-145}"
RUN_ID="${RUN_ID:-n1-interior-$(date +%Y%m%d-%H%M%S)-$$}"
OUT="${OUT:-$EXP/evidence/interior-$RUN_ID}"
POLL_SECONDS="${POLL_SECONDS:-5}"
STALL_SECONDS="${STALL_SECONDS:-600}"
TOTAL_SECONDS="${TOTAL_SECONDS:-1800}"
FAMILY="${COSYVOICE3_N1_FAMILY:-}"
EXTENSION_RECEIPT="${COSYVOICE3_N1_EXTENSION_RECEIPT:-}"
: "${DEVELOPMENT_TEAM:?export DEVELOPMENT_TEAM=<Apple-development-team-id>}"

find_family() {
  "$PYTHON" - "$ROOT/ios/.work/dynamic-acoustic" <<'PY'
import json,pathlib,sys
rows=[]
for p in pathlib.Path(sys.argv[1]).glob("lower-bound-family-n1-v*"):
    try:
        r=json.load(open(p/"receipt.json"))
        if r.get("status")=="PASS_FULL_RANGE_SYMBOLIC_FAMILY_EXPORT_NOT_PROMOTED" and r.get("NBounds")==[1,479]:
            rows.append((p.stat().st_mtime,p))
    except Exception:
        pass
if rows:
    print(max(rows)[1])
PY
}

find_extension() {
  "$PYTHON" - "$EXP/evidence" <<'PY'
import json,pathlib,sys
rows=[]
for p in pathlib.Path(sys.argv[1]).glob("lower-bound-*"):
    q=p/"lower-bound-extension-receipt.json"
    try:
        r=json.load(open(q))
        if r.get("status")=="PASS_N1_N2_LOWER_BOUND_EXTENSION_NOT_PROMOTED":
            rows.append((q.stat().st_mtime,q))
    except Exception:
        pass
if rows:
    print(max(rows)[1])
PY
}

mkdir -p "$OUT"
echo "===== VERIFY SOURCE ====="
[[ "$(git -C "$ROOT" branch --show-current)" == "$BRANCH" ]] || { echo "ERROR: switch to $BRANCH"; exit 2; }
git -C "$ROOT" rev-parse HEAD
git -C "$ROOT" status --short
[[ -x "$PYTHON" ]] || { echo "ERROR: missing dynamic Python $PYTHON"; exit 2; }

if [[ -z "$FAMILY" ]]; then FAMILY="$(find_family)"; fi
if [[ -z "$EXTENSION_RECEIPT" ]]; then EXTENSION_RECEIPT="$(find_extension)"; fi
[[ -f "$FAMILY/receipt.json" ]] || { echo "ERROR: PASS N1 family missing: $FAMILY"; exit 2; }
[[ -f "$EXTENSION_RECEIPT" ]] || { echo "ERROR: PASS N1 extension receipt missing: $EXTENSION_RECEIPT"; exit 2; }

echo "===== VERIFY FAMILY BINDING ====="
"$PYTHON" - "$FAMILY/receipt.json" "$EXTENSION_RECEIPT" "$NVALUES" <<'PY'
import hashlib,json,sys
family_path,extension_path,raw=sys.argv[1:]
def sha(path):
 h=hashlib.sha256()
 with open(path,"rb") as f:
  for b in iter(lambda:f.read(8*1024*1024),b""): h.update(b)
 return h.hexdigest()
f=json.load(open(family_path));e=json.load(open(extension_path))
values=[int(x) for x in raw.split(",") if x]
assert f["status"]=="PASS_FULL_RANGE_SYMBOLIC_FAMILY_EXPORT_NOT_PROMOTED",f.get("status")
assert f["NBounds"]==[1,479],f.get("NBounds")
assert e["status"]=="PASS_N1_N2_LOWER_BOUND_EXTENSION_NOT_PROMOTED",e.get("status")
assert e["newFamilyReceiptSha256"]==sha(family_path),(e["newFamilyReceiptSha256"],sha(family_path))
assert values and all(1<=n<=479 for n in values),values
print("FAMILY_RECEIPT_SHA256",sha(family_path))
print("EXTENSION_STATUS",e["status"])
print("NVALUES",values)
PY

echo "===== STAGE EXACT N1 FAMILY ====="
rm -rf "$EXP/DeviceProbe/GeneratedAssets/acoustic"
"$PYTHON" "$EXP/stage_full_range_probe.py" --family "$FAMILY" | tee "$OUT/stage.log"

echo "===== SELECT PHYSICAL IPHONE ====="
DESTINATIONS="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -showdestinations 2>&1)"
printf '%s\n' "$DESTINATIONS" | tee "$OUT/destinations.log"
if [[ -z "${DEVICE_ID:-}" ]] || ! printf '%s\n' "$DESTINATIONS" | grep -F "id:$DEVICE_ID" >"$OUT/device-match.txt"; then
  DEVICE_ID="$(printf '%s\n' "$DESTINATIONS" | sed -n 's/.*{ platform:iOS, arch:arm64, id:\([^,}]*\), name:.*/\1/p' | head -n 1 | xargs)"
fi
[[ -n "$DEVICE_ID" ]] || { echo "ERROR: no physical iPhone"; exit 2; }
echo "DEVICE_ID=$DEVICE_ID"

echo "===== BUILD FOCUSED PROBE ====="
BUILD_SETTINGS="$OUT/build-settings.txt"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIGURATION" -destination "id=$DEVICE_ID" DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" CODE_SIGN_STYLE=Automatic -showBuildSettings | tee "$BUILD_SETTINGS"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIGURATION" -destination "id=$DEVICE_ID" DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" CODE_SIGN_STYLE=Automatic build | tee "$OUT/build.log"
TARGET_BUILD_DIR="$(awk -F ' = ' '/^[[:space:]]*TARGET_BUILD_DIR = /{v=$2} END{print v}' "$BUILD_SETTINGS")"
FULL_PRODUCT_NAME="$(awk -F ' = ' '/^[[:space:]]*FULL_PRODUCT_NAME = /{v=$2} END{print v}' "$BUILD_SETTINGS")"
APP="$TARGET_BUILD_DIR/$FULL_PRODUCT_NAME"
[[ -d "$APP" ]] || { echo "ERROR: built app missing: $APP"; exit 3; }

echo "===== RECLAIM DEVICE STORAGE BEFORE PROBE INSTALL ====="
if xcrun devicectl device uninstall app --device "$DEVICE_ID" "$DEVICE_SMOKE_BUNDLE"; then
  echo "REMOVED $DEVICE_SMOKE_BUNDLE"
else
  echo "INFO: $DEVICE_SMOKE_BUNDLE was absent or removal was unnecessary"
fi
if xcrun devicectl device uninstall app --device "$DEVICE_ID" "$BUNDLE_ID"; then
  echo "REMOVED prior $BUNDLE_ID"
else
  echo "INFO: prior $BUNDLE_ID was absent"
fi

echo "===== INSTALL FOCUSED PROBE ====="
xcrun devicectl device install app --device "$DEVICE_ID" "$APP" | tee "$OUT/install.log"

echo "===== RUN NVALUES=$NVALUES WITH VALIDATED ACOUSTIC CONFIG ====="
REMOTE="dynamic-acoustic-shape-sweep-CPU_AND_NE-values-$RUN_ID.json"
LOCAL="$OUT/$REMOTE"
TMP="$LOCAL.tmp"
COPY_LOG="$OUT/copy.log"
xcrun devicectl device process launch --device "$DEVICE_ID" --terminate-existing "$BUNDLE_ID" -- ACOUSTIC_SWEEP CPU_AND_NE "NVALUES=$NVALUES" "RUN_ID=$RUN_ID" | tee "$OUT/launch.log"

START="$(date +%s)"
LAST_CHANGE="$START"
LAST_KEY=""
while true; do
  rm -f "$TMP"
  if xcrun devicectl device copy from --device "$DEVICE_ID" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" --source "Documents/$REMOTE" --destination "$TMP" >"$COPY_LOG" 2>&1 && [[ -s "$TMP" ]]; then
    ROW="$(python3 - "$TMP" <<'PY'
import json,sys
try:
 r=json.load(open(sys.argv[1]));tests=r.get("tests",[]);last=tests[-1] if tests else {}
 print("|".join(map(str,[r.get("status",""),r.get("phase",""),len(tests),last.get("N",""),last.get("status","")])))
except Exception:
 print("||||")
PY
)"
    IFS='|' read -r STATUS PHASE COUNT LAST_N LAST_STATUS <<<"$ROW"
    KEY="$PHASE|$COUNT|$LAST_N|$LAST_STATUS"
    NOW="$(date +%s)"
    if [[ "$KEY" != "$LAST_KEY" ]]; then
      echo "INTERIOR progress phase=$PHASE tests=$COUNT lastN=${LAST_N:-NA} lastStatus=${LAST_STATUS:-NA}"
      LAST_KEY="$KEY"
      LAST_CHANGE="$NOW"
    fi
    if [[ -n "$STATUS" && "$STATUS" != "RUNNING" ]]; then
      mv "$TMP" "$LOCAL"
      break
    fi
    if (( NOW-LAST_CHANGE >= STALL_SECONDS )); then
      cp "$TMP" "$LOCAL"
      echo "ERROR: focused interior probe made no durable progress for $STALL_SECONDS seconds"
      python3 -m json.tool "$LOCAL"
      exit 4
    fi
  fi
  NOW="$(date +%s)"
  if (( NOW-START >= TOTAL_SECONDS )); then
    if [[ -s "$TMP" ]]; then cp "$TMP" "$LOCAL"; fi
    echo "ERROR: focused interior probe exceeded total $TOTAL_SECONDS seconds"
    [[ -s "$LOCAL" ]] && python3 -m json.tool "$LOCAL"
    exit 5
  fi
  sleep "$POLL_SECONDS"
done

echo "===== VERIFY FOCUSED RESULT ====="
"$PYTHON" - "$LOCAL" "$NVALUES" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]));expected=[int(x) for x in sys.argv[2].split(",") if x]
assert r["status"]=="PASS_EXHAUSTIVE_INTEGER_DYNAMIC_SHAPE_SWEEP_NOT_PROMOTED",r.get("status")
assert r["exportedNBounds"]==[1,479],r.get("exportedNBounds")
got=[x["N"] for x in r.get("tests",[]) if x.get("status")=="PASS_SHAPE_EXECUTION"]
assert got==expected,(got,expected)
for row in r["tests"]:
 assert row["T"]==302+2*row["N"],row
 assert row["G"]==2*row["N"],row
 assert row["expectedSamples"]==960*row["N"],row
print("PASS_N1_INTERIOR_SHAPE_PROBE",got)
print("BACKEND",r["backend"],r["backendMeaning"])
PY

echo "===== UNINSTALL PROBE TO RETURN DEVICE STORAGE ====="
if xcrun devicectl device uninstall app --device "$DEVICE_ID" "$BUNDLE_ID"; then
  echo "REMOVED $BUNDLE_ID"
else
  echo "INFO: probe uninstall returned nonzero; evidence is already retained on host"
fi

echo "PASS evidence=$OUT"
echo "NEXT: rerun run_n1_candidate_public_api_smoke.sh against current source HEAD"

# Code purpose: focused physical reproduction/clearance of an interior N1-family Core ML shape, default N145/T592, before spending time on another full public-API smoke.
# Upstream source: exact PASS lower-bound N1 family and the same AcousticShapeSweepProbe that established N1/N2/N3/N225/N479; CPU_AND_NE requested units plus reshapeFrequency=.infrequent.
# Runtime environment: macOS Xcode/xcrun, signed physical iPhone.
# Generated time: 2026-10-04 America/New_York.
# Changes: new focused interior-shape gate; reclaims device storage before install and uninstalls probe after host evidence is retained; no production promotion.
