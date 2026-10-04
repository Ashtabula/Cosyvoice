#!/bin/bash
set -euo pipefail

# Requirement: extend the already-proven N3...479 symbolic acoustic envelope down to N1 without rerunning all 477 prior integers. Re-export the same source graphs with lower RangeDim bounds, prove source-graph/CoreML-weight carry-forward equivalence, physically execute N1/N2 plus overlapping N3/N225/N479 on one iPhone, and prove N0/N480 rejection. Do not promote release assets.
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
EXP="$ROOT/ios/experiments/dynamic-acoustic"
PYTHON="${COSYVOICE3_DYNAMIC_PYTHON:-$ROOT/ios/.work/dynamic-acoustic/venv/bin/python}"
PROJECT="$EXP/DeviceProbe/DynamicAcousticProbe.xcodeproj"
SCHEME="DynamicAcousticProbe"
BUNDLE_ID="com.actacomes.cosyvoice3.dynamicacoustic"
CONFIGURATION="Release"
BRANCH="experiment/ios-dynamic-acoustic"
OLD_FAMILY="${COSYVOICE3_N3_FAMILY:-}"
OLD_SWEEP="${COSYVOICE3_N3_SWEEP_DIR:-}"
NEW_FAMILY="${COSYVOICE3_N1_FAMILY:-}"
RUN_ID="${RUN_ID:-n1-extension-$(date +%Y%m%d-%H%M%S)-$$}"
OUT="${OUT:-$EXP/evidence/lower-bound-$RUN_ID}"
POLL_SECONDS="${POLL_SECONDS:-5}"
STALL_SECONDS="${STALL_SECONDS:-1800}"
: "${DEVELOPMENT_TEAM:?export DEVELOPMENT_TEAM=<Apple-development-team-id>}"

find_old_family() {
  "$PYTHON" - "$ROOT/ios/.work/dynamic-acoustic" <<'PY'
import json,pathlib,sys
rows=[]
for p in pathlib.Path(sys.argv[1]).glob("full-range-family-v*"):
    try:
        r=json.load(open(p/"receipt.json"))
        if r.get("status")=="PASS_FULL_RANGE_SYMBOLIC_FAMILY_EXPORT_NOT_PROMOTED" and r.get("NBounds")==[3,479]:
            rows.append((p.stat().st_mtime,p))
    except Exception: pass
if rows: print(max(rows)[1])
PY
}

find_old_sweep() {
  "$PYTHON" - "$EXP/evidence" <<'PY'
import pathlib,sys
rows=[]
for p in pathlib.Path(sys.argv[1]).glob("acoustic-n479-sweep-*"):
    if p.is_dir() and (p/"chunks").is_dir(): rows.append((p.stat().st_mtime,p))
if rows: print(max(rows)[1])
PY
}

verify_old_sweep() {
  "$PYTHON" - "$1" <<'PY'
import json,pathlib,sys
root=pathlib.Path(sys.argv[1]);rows=[]
for p in sorted((root/"chunks").glob("dynamic-acoustic-shape-sweep-CPU_AND_NE-N*.json")):
    r=json.load(open(p))
    if r.get("status")!="PASS_EXHAUSTIVE_INTEGER_DYNAMIC_SHAPE_SWEEP_NOT_PROMOTED":
        raise SystemExit(f"old sweep chunk not PASS: {p}")
    rows.extend(r.get("tests",[]))
ns=sorted(x["N"] for x in rows if x.get("status")=="PASS_SHAPE_EXECUTION")
if ns!=list(range(3,480)): raise SystemExit(f"old N3...479 coverage mismatch count={len(ns)}")
print("OLD_SWEEP PASS_FULL_N3_TO_N479_INTEGER_SWEEP count=477")
PY
}

mkdir -p "$OUT"
[[ "$(git -C "$ROOT" branch --show-current)" == "$BRANCH" ]] || { echo "ERROR: switch to $BRANCH"; exit 2; }
[[ -x "$PYTHON" ]] || { echo "ERROR: missing dynamic Python $PYTHON"; exit 2; }

if [[ -z "$OLD_FAMILY" ]]; then OLD_FAMILY="$(find_old_family)"; fi
[[ -n "$OLD_FAMILY" && -f "$OLD_FAMILY/receipt.json" ]] || { echo "ERROR: prior PASS N3...479 family not found"; exit 2; }
if [[ -z "$OLD_SWEEP" ]]; then OLD_SWEEP="$(find_old_sweep)"; fi
[[ -n "$OLD_SWEEP" && -d "$OLD_SWEEP/chunks" ]] || { echo "ERROR: prior complete N3...479 sweep not found"; exit 2; }
verify_old_sweep "$OLD_SWEEP"

if [[ -z "$NEW_FAMILY" ]]; then
  for i in $(seq 1 99); do
    candidate="$ROOT/ios/.work/dynamic-acoustic/lower-bound-family-n1-v$i"
    if [[ ! -e "$candidate" ]]; then NEW_FAMILY="$candidate"; break; fi
  done
fi
[[ -n "$NEW_FAMILY" && ! -e "$NEW_FAMILY" ]] || { echo "ERROR: fresh NEW_FAMILY required: $NEW_FAMILY"; exit 2; }

echo "===== EXPORT N1...479 FAMILY ====="
"$PYTHON" "$EXP/export_full_range_family.py" --n-min 1 --n-max 479 --output "$NEW_FAMILY" | tee "$OUT/export.log"

echo "===== VERIFY LOWER-BOUND-ONLY SOURCE/PAYLOAD CHANGE ====="
"$PYTHON" - "$OLD_FAMILY" "$NEW_FAMILY" "$OUT/equivalence.json" <<'PY'
import hashlib,json,pathlib,sys,torch
old,new,out=map(pathlib.Path,sys.argv[1:])
def sha(p):
 h=hashlib.sha256()
 with open(p,"rb") as f:
  for b in iter(lambda:f.read(8*1024*1024),b""): h.update(b)
 return h.hexdigest()
def bins(root):
 return {str(p.relative_to(root)):sha(p) for p in sorted(root.rglob("*.bin")) if p.is_file()}
ro=json.load(open(old/"receipt.json"));rn=json.load(open(new/"receipt.json"))
if ro.get("NBounds")!=[3,479] or rn.get("NBounds")!=[1,479]: raise SystemExit("unexpected family bounds")
if ro.get("pinnedUpstream")!=rn.get("pinnedUpstream"): raise SystemExit("pinned upstream changed")
graph_rows={}
pairs=[("conditions",old/"conditions/source.pt2",new/"conditions/source.pt2")]
for i in range(6): pairs.append((f"flow-{i}",old/f"packages/shard-{i:02d}/source.pt2",new/f"packages/shard-{i:02d}/source.pt2"))
pairs.append(("hift",old/"hift/source.pt2",new/"hift/source.pt2"))
for name,a,b in pairs:
 ea,eb=torch.export.load(a),torch.export.load(b)
 same_code=ea.graph_module.code==eb.graph_module.code
 ka,kb=list(ea.state_dict.keys()),list(eb.state_dict.keys())
 same_state_keys=ka==kb
 same_state= same_state_keys and all(torch.equal(ea.state_dict[k],eb.state_dict[k]) for k in ka)
 graph_rows[name]={"graphCodeExact":same_code,"stateKeysExact":same_state_keys,"stateTensorsExact":same_state}
 if not (same_code and same_state): raise SystemExit(f"{name}: source graph/state changed beyond range constraints")
payload_rows={}
package_pairs=[("conditions",old/"conditions/conditions.mlpackage",new/"conditions/conditions.mlpackage")]
for i in range(6): package_pairs.append((f"flow-{i}",old/f"packages/shard-{i:02d}/flow-shard.mlpackage",new/f"packages/shard-{i:02d}/flow-shard.mlpackage"))
package_pairs.append(("hift",old/"hift/hift-dynamic-body-fp32.mlpackage",new/"hift/hift-dynamic-body-fp32.mlpackage"))
for name,a,b in package_pairs:
 ba,bb=bins(a),bins(b);same=ba==bb
 payload_rows[name]={"weightBinPayloadExact":same,"old":ba,"new":bb}
 if not same: raise SystemExit(f"{name}: CoreML .bin payload changed")
result={
 "schemaVersion":1,
 "status":"PASS_LOWER_BOUND_SOURCE_AND_WEIGHT_EQUIVALENCE",
 "oldNBounds":[3,479],"newNBounds":[1,479],
 "meaning":"torch.export graph code and state tensors are exact; CoreML .bin payloads are exact. Shape-range metadata is intentionally widened at the lower bound.",
 "sourceGraphs":graph_rows,"coreMLPayloads":payload_rows
}
out.write_text(json.dumps(result,indent=2,sort_keys=True)+"\n")
print(json.dumps(result,indent=2,sort_keys=True))
PY

echo "===== STAGE N1...479 DEVICE ASSETS ====="
rm -rf "$EXP/DeviceProbe/GeneratedAssets/acoustic"
"$PYTHON" "$EXP/stage_full_range_probe.py" --family "$NEW_FAMILY" | tee "$OUT/stage.log"

echo "===== BUILD PHYSICAL PROBE ====="
DESTINATIONS="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -showdestinations 2>&1)"
printf '%s\n' "$DESTINATIONS" | tee "$OUT/destinations.log"
if [[ -z "${DEVICE_ID:-}" ]] || ! printf '%s\n' "$DESTINATIONS" | grep -F "id:$DEVICE_ID" >"$OUT/device-match.txt"; then
  DEVICE_ID="$(printf '%s\n' "$DESTINATIONS" | sed -n 's/.*{ platform:iOS, arch:arm64, id:\([^,}]*\), name:.*/\1/p' | head -n 1 | xargs)"
fi
[[ -n "$DEVICE_ID" ]] || { echo "ERROR: no available physical iPhone"; exit 2; }
echo "DEVICE_ID=$DEVICE_ID"

BUILD_SETTINGS="$OUT/build-settings.txt"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIGURATION" -destination "id=$DEVICE_ID" DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" CODE_SIGN_STYLE=Automatic -showBuildSettings | tee "$BUILD_SETTINGS"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIGURATION" -destination "id=$DEVICE_ID" DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" CODE_SIGN_STYLE=Automatic build | tee "$OUT/build.log"
TARGET_BUILD_DIR="$(awk -F ' = ' '/^[[:space:]]*TARGET_BUILD_DIR = /{v=$2} END{print v}' "$BUILD_SETTINGS")"
FULL_PRODUCT_NAME="$(awk -F ' = ' '/^[[:space:]]*FULL_PRODUCT_NAME = /{v=$2} END{print v}' "$BUILD_SETTINGS")"
APP="$TARGET_BUILD_DIR/$FULL_PRODUCT_NAME"
test -d "$APP"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP" | tee "$OUT/install.log"

echo "===== PHYSICAL N1/N2 + OVERLAP CHECKPOINTS ====="
REMOTE="dynamic-acoustic-shape-sweep-CPU_AND_NE-values-$RUN_ID.json"
LOCAL="$OUT/$REMOTE"
xcrun devicectl device process launch --device "$DEVICE_ID" --terminate-existing "$BUNDLE_ID" -- ACOUSTIC_SWEEP CPU_AND_NE "NVALUES=1,2,3,225,479" "RUN_ID=$RUN_ID" | tee "$OUT/launch.log"

last_key="";last_change="$(date +%s)"
while true; do
  tmp="$LOCAL.tmp";rm -f "$tmp"
  if xcrun devicectl device copy from --device "$DEVICE_ID" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" --source "Documents/$REMOTE" --destination "$tmp" >"$OUT/copy.log" 2>&1 && [[ -s "$tmp" ]]; then
    row="$(python3 - "$tmp" <<'PY'
import json,sys
try:
 r=json.load(open(sys.argv[1]));tests=r.get("tests",[]);last=tests[-1] if tests else {}
 print("|".join(map(str,[r.get("status",""),r.get("phase",""),len(tests),last.get("N",""),last.get("status","")])))
except Exception: print("||||")
PY
)"
    IFS='|' read -r status phase count last_n last_status <<<"$row"
    key="$phase|$count|$last_n|$last_status";now="$(date +%s)"
    if [[ -n "$phase" && "$key" != "$last_key" ]]; then
      echo "LOWER_BOUND progress phase=$phase tests=$count lastN=${last_n:-NA} lastStatus=${last_status:-NA}"
      last_key="$key";last_change="$now"
    fi
    if [[ -n "$status" && "$status" != "RUNNING" ]]; then mv "$tmp" "$LOCAL";break;fi
    if (( now-last_change >= STALL_SECONDS )); then cp "$tmp" "$LOCAL";echo "ERROR: no progress for $STALL_SECONDS seconds";python3 -m json.tool "$LOCAL";exit 3;fi
  fi
  sleep "$POLL_SECONDS"
done

echo "===== VERIFY + WRITE EXTENSION RECEIPT ====="
"$PYTHON" - "$OLD_FAMILY" "$OLD_SWEEP" "$NEW_FAMILY" "$OUT/equivalence.json" "$LOCAL" "$OUT/lower-bound-extension-receipt.json" <<'PY'
import hashlib,json,pathlib,sys
old_family,old_sweep,new_family,equiv_path,device_path,out=map(pathlib.Path,sys.argv[1:])
def sha(p):
 h=hashlib.sha256()
 with open(p,"rb") as f:
  for b in iter(lambda:f.read(8*1024*1024),b""): h.update(b)
 return h.hexdigest()
e=json.load(open(equiv_path));d=json.load(open(device_path))
if e.get("status")!="PASS_LOWER_BOUND_SOURCE_AND_WEIGHT_EQUIVALENCE": raise SystemExit("equivalence gate failed")
if d.get("status")!="PASS_EXHAUSTIVE_INTEGER_DYNAMIC_SHAPE_SWEEP_NOT_PROMOTED": raise SystemExit(f"device status {d.get('status')}")
expected=[1,2,3,225,479]
got=[x.get("N") for x in d.get("tests",[]) if x.get("status")=="PASS_SHAPE_EXECUTION"]
if got!=expected: raise SystemExit(f"physical checkpoint mismatch {got}")
neg=d.get("negativeBoundaryTests",[])
pairs={(x.get("N"),x.get("status")) for x in neg}
if (0,"PASS_REJECTED_OUT_OF_RANGE") not in pairs or (480,"PASS_REJECTED_OUT_OF_RANGE") not in pairs:
 raise SystemExit(f"N0/N480 rejection missing: {neg}")
r={
 "schemaVersion":1,
 "status":"PASS_N1_N2_LOWER_BOUND_EXTENSION_NOT_PROMOTED",
 "newNBounds":[1,479],
 "newTBounds":[304,1260],
 "newGBounds":[2,958],
 "newPCMSampleBounds":[960,459840],
 "physicalCheckpointN":[1,2,3,225,479],
 "negativeBoundaryN":[0,480],
 "priorExhaustiveNBounds":[3,479],
 "priorExhaustiveIntegerCount":477,
 "carryForwardBasis":"exact torch.export graph code/state tensors + exact CoreML .bin payloads + overlapping physical N3/N225/N479 on widened-range packages",
 "priorSweepPath":str(old_sweep),
 "oldFamilyReceiptSha256":sha(old_family/"receipt.json"),
 "newFamilyReceiptSha256":sha(new_family/"receipt.json"),
 "equivalenceReceiptSha256":sha(equiv_path),
 "deviceReceiptSha256":sha(device_path),
 "productionPromotion":False
}
out.write_text(json.dumps(r,indent=2,sort_keys=True)+"\n")
print(json.dumps(r,indent=2,sort_keys=True))
print("PASS_N1_TO_N479_ENVELOPE_EXTENSION_NOT_PROMOTED")
PY

echo "PASS evidence=$OUT"
echo "NEW_FAMILY=$NEW_FAMILY"
echo "NEXT: build N1...479 integration candidate gated by lower-bound-extension-receipt.json"

# Code purpose: focused lower-bound extension from the already exhaustive physical N3...479 proof to N1...479, without needlessly rerunning all previously covered integers.
# Upstream source: exact current dynamic exporter, prior complete N3...479 physical sweep, and the same pinned upstream model/checkpoint.
# Runtime environment: macOS arm64 dynamic Python, Xcode/coremlcompiler, signed physical iPhone.
# Generated time: 2026-10-04 America/New_York.
# Changes: N1 re-export, source/weight equivalence gate, physical N1/N2 plus overlapping N3/N225/N479 execution, N0/N480 rejection, explicit carry-forward receipt; no release promotion.
