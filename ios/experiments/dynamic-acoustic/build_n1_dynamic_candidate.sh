#!/bin/bash
set -euo pipefail

# Requirement: after PASS_N1_N2_LOWER_BOUND_EXTENSION_NOT_PROMOTED, assemble a fresh N1...479 SDK candidate from the physically proven widened family while reusing the already provenance-bound Nmax=479 stochastic buffers and accepted fixed225 oracle assets. Do not promote release assets.
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
EXP="$ROOT/ios/experiments/dynamic-acoustic"
PYTHON="${COSYVOICE3_DYNAMIC_PYTHON:-$ROOT/ios/.work/dynamic-acoustic/venv/bin/python}"
BRANCH="experiment/ios-dynamic-acoustic"
FAMILY="${COSYVOICE3_N1_FAMILY:-}"
EXTENSION_RECEIPT="${COSYVOICE3_N1_EXTENSION_RECEIPT:-}"
BASE_CANDIDATE="${COSYVOICE3_N3_INTEGRATION_WORK:-$ROOT/ios/.work/dynamic-acoustic/integration-candidate-v1}"
WORK="${COSYVOICE3_N1_INTEGRATION_WORK:-}"
FIXED_RUNTIME="${COSYVOICE3_FIXED_ASSET_ROOT:-}"
FIXTURE="${COSYVOICE3_DYNAMIC_FIXTURE:-$ROOT/ios/.work/rebuild/ios-fixed225-reference/fixture}"

find_family() {
  "$PYTHON" - "$ROOT/ios/.work/dynamic-acoustic" <<'PY'
import json,pathlib,sys
rows=[]
for p in pathlib.Path(sys.argv[1]).glob("lower-bound-family-n1-v*"):
    try:
        r=json.load(open(p/"receipt.json"))
        if r.get("status")=="PASS_FULL_RANGE_SYMBOLIC_FAMILY_EXPORT_NOT_PROMOTED" and r.get("NBounds")==[1,479]:
            rows.append((p.stat().st_mtime,p))
    except Exception: pass
if rows: print(max(rows)[1])
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
        if r.get("status")=="PASS_N1_N2_LOWER_BOUND_EXTENSION_NOT_PROMOTED": rows.append((q.stat().st_mtime,q))
    except Exception: pass
if rows: print(max(rows)[1])
PY
}
find_fixed() {
  for p in "$ROOT/ios/.work/production-clean-room/fetched-runtime" "$ROOT/ios/.work/rebuilt-runtime/ios-fixed225-reference" "$ROOT/ios/validation/DeviceSmoke/GeneratedAssets/Runtime"; do
    if [[ -f "$p/cosyvoice3_fixed225.json" ]]; then printf '%s\n' "$p";return 0;fi
  done
  return 1
}

[[ "$(git -C "$ROOT" branch --show-current)" == "$BRANCH" ]] || { echo "ERROR: switch to $BRANCH"; exit 2; }
[[ -x "$PYTHON" ]] || { echo "ERROR: missing dynamic Python $PYTHON"; exit 2; }

if [[ -z "$FAMILY" ]]; then FAMILY="$(find_family)";fi
[[ -n "$FAMILY" && -f "$FAMILY/receipt.json" ]] || { echo "ERROR: PASS N1...479 family not found";exit 2; }
if [[ -z "$EXTENSION_RECEIPT" ]]; then EXTENSION_RECEIPT="$(find_extension)";fi
[[ -n "$EXTENSION_RECEIPT" && -f "$EXTENSION_RECEIPT" ]] || { echo "ERROR: PASS lower-bound extension receipt not found";exit 2; }
if [[ -z "$FIXED_RUNTIME" ]]; then FIXED_RUNTIME="$(find_fixed)";fi
[[ -n "$FIXED_RUNTIME" && -f "$FIXED_RUNTIME/cosyvoice3_fixed225.json" ]] || { echo "ERROR: accepted fixed runtime not found";exit 2; }

BUFFER_DIR="$BASE_CANDIDATE/buffers"
[[ -f "$BUFFER_DIR/receipt.json" && -f "$BUFFER_DIR/flow-noise-max.f32" && -f "$BUFFER_DIR/hift-excitation-max.f32" ]] || {
  echo "ERROR: provenance-bound Nmax=479 buffers missing under $BUFFER_DIR";exit 2;
}

if [[ -z "$WORK" ]]; then
  for i in $(seq 1 99); do
    candidate="$ROOT/ios/.work/dynamic-acoustic/integration-candidate-n1-v$i"
    if [[ ! -e "$candidate" ]]; then WORK="$candidate";break;fi
  done
fi
[[ -n "$WORK" && ! -e "$WORK" ]] || { echo "ERROR: fresh WORK required: $WORK";exit 2; }
mkdir -p "$WORK"

echo "===== VERIFY EXTENSION GATE ====="
"$PYTHON" - "$FAMILY/receipt.json" "$EXTENSION_RECEIPT" "$BUFFER_DIR/receipt.json" <<'PY'
import json,sys
f,e,b=map(lambda p:json.load(open(p)),sys.argv[1:])
assert f["status"]=="PASS_FULL_RANGE_SYMBOLIC_FAMILY_EXPORT_NOT_PROMOTED" and f["NBounds"]==[1,479],f
assert e["status"]=="PASS_N1_N2_LOWER_BOUND_EXTENSION_NOT_PROMOTED" and e["newNBounds"]==[1,479],e
assert b["status"]=="PASS_CANDIDATE_STOCHASTIC_BUFFERS_GENERATED_NOT_PROMOTED" and b["nmax"]==479,b
print("EXTENSION_STATUS",e["status"])
print("N_BOUNDS",e["newNBounds"])
print("CARRY_FORWARD",e["carryForwardBasis"])
PY

echo "===== SWIFT TEST ====="
swift test --package-path "$ROOT/ios" | tee "$WORK/swift-test.log"

echo "===== BUILD N1...479 CANDIDATE ====="
"$PYTHON" "$EXP/build_dynamic_candidate_assets.py" \
  --family "$FAMILY" \
  --fixed-runtime "$FIXED_RUNTIME" \
  --fixture "$FIXTURE" \
  --flow-noise-max "$BUFFER_DIR/flow-noise-max.f32" \
  --hift-excitation-max "$BUFFER_DIR/hift-excitation-max.f32" \
  --buffer-receipt "$BUFFER_DIR/receipt.json" \
  --lower-bound-extension-receipt "$EXTENSION_RECEIPT" \
  --output "$WORK/runtime" | tee "$WORK/candidate-assets.log"

echo "===== VERIFY CANDIDATE ====="
"$PYTHON" "$ROOT/ios/assets/validate_assets.py" --root "$WORK/runtime" --require-reference
"$PYTHON" - "$WORK/runtime/cosyvoice3_dynamic.json" "$WORK/runtime/dynamic-candidate-receipt.json" <<'PY'
import json,sys
m=json.load(open(sys.argv[1]));r=json.load(open(sys.argv[2]))
assert m["profile"]=="ios18-dynamic-n1-n479-candidate",m["profile"]
assert m["dynamicAcoustic"]["speechTokenMinimum"]==1
assert m["dynamicAcoustic"]["speechTokenMaximum"]==479
assert r["status"]=="PASS_DYNAMIC_CANDIDATE_ASSET_ROOT_BUILT_NOT_PROMOTED"
assert r["NBounds"]==[1,479]
assert r["lowerBoundPhysicalExtensionStatus"]=="PASS_N1_N2_LOWER_BOUND_EXTENSION_NOT_PROMOTED"
assert r["productionPromotion"] is False
print("PROFILE",m["profile"])
print("N_BOUNDS",r["NBounds"])
print("LOWER_BOUND_GATE",r["lowerBoundPhysicalExtensionStatus"])
print("PRODUCTION_PROMOTION",r["productionPromotion"])
PY

echo "PASS CANDIDATE_ROOT=$WORK/runtime"
echo "NEXT: run dynamic public-API default+reference smoke against this exact candidate root, then perform human listening acceptance before any promotion."

# Code purpose: build the first N1...479 dynamic integration candidate only after focused physical lower-bound proof, while reusing unchanged Nmax=479 stochastic buffers and fixed225 oracle assets.
# Upstream source: PASS N1 lower-bound family/evidence, accepted fixed225 runtime and prior provenance-bound dynamic stochastic buffers.
# Runtime environment: macOS arm64 Swift6 + dynamic Python3.11.
# Generated time: 2026-10-04 America/New_York.
# Changes: new lower-bound-gated integration builder; no production promotion.
