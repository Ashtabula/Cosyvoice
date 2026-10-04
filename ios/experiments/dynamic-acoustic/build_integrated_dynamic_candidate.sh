#!/bin/bash
set -euo pipefail

# Requirement: after the physical N3...479 sweep is complete, compile/test the integrated SDK, generate production-candidate max stochastic buffers, and assemble an isolated dual-oracle dynamic candidate asset root. Do not mutate or promote the frozen fixed225 runtime.
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
EXP="$ROOT/ios/experiments/dynamic-acoustic"
PYTHON="${COSYVOICE3_DYNAMIC_PYTHON:-$ROOT/ios/.work/dynamic-acoustic/venv/bin/python}"
SOURCE="${COSYVOICE3_DYNAMIC_SOURCE:-$ROOT/ios/.work/rebuild/ios-fixed225-reference/source}"
MODEL="${COSYVOICE3_DYNAMIC_MODEL:-$ROOT/ios/.work/rebuild/ios-fixed225-reference/model-cache/Fun-CosyVoice3-0.5B-2512}"
FIXTURE="${COSYVOICE3_DYNAMIC_FIXTURE:-$ROOT/ios/.work/rebuild/ios-fixed225-reference/fixture}"
BRANCH="experiment/ios-dynamic-acoustic"
SWEEP_DIR="${COSYVOICE3_FULL_RANGE_SWEEP_DIR:-}"
FAMILY="${COSYVOICE3_FULL_RANGE_FAMILY:-}"
WORK="${COSYVOICE3_DYNAMIC_INTEGRATION_WORK:-}"

find_fixed_asset_root() {
  if [[ -n "${COSYVOICE3_FIXED_ASSET_ROOT:-}" ]]; then printf '%s\n' "$COSYVOICE3_FIXED_ASSET_ROOT"; return 0; fi
  for candidate in     "$ROOT/ios/.work/production-clean-room/fetched-runtime"     "$ROOT/ios/.work/rebuilt-runtime/ios-fixed225-reference"     "$ROOT/ios/validation/DeviceSmoke/GeneratedAssets/Runtime"
  do
    if [[ -f "$candidate/cosyvoice3_fixed225.json" ]]; then printf '%s\n' "$candidate"; return 0; fi
  done
  return 1
}

find_pass_family() {
  "$PYTHON" - "$ROOT/ios/.work/dynamic-acoustic" <<'PY'
import json,pathlib,sys
root=pathlib.Path(sys.argv[1])
rows=[]
for p in root.glob("full-range-family-v*"):
    try:
        r=json.load(open(p/"receipt.json"))
        if r.get("status")=="PASS_FULL_RANGE_SYMBOLIC_FAMILY_EXPORT_NOT_PROMOTED" and r.get("NBounds")==[3,479]:
            rows.append((p.stat().st_mtime,p))
    except Exception: pass
if rows: print(max(rows)[1])
PY
}

find_sweep_dir() {
  "$PYTHON" - "$EXP/evidence" <<'PY'
import pathlib,sys
rows=[]
for p in pathlib.Path(sys.argv[1]).glob("acoustic-n479-sweep-*"):
    if p.is_dir(): rows.append((p.stat().st_mtime,p))
if rows: print(max(rows)[1])
PY
}

verify_sweep() {
  "$PYTHON" - "$1" <<'PY'
import json,pathlib,sys
root=pathlib.Path(sys.argv[1])
checkpoint=list(root.glob("dynamic-acoustic-shape-sweep-CPU_AND_NE-values-*.json"))
if len(checkpoint)!=1: raise SystemExit(f"expected one checkpoint receipt, got {len(checkpoint)}")
c=json.load(open(checkpoint[0]))
if c.get("status")!="PASS_EXHAUSTIVE_INTEGER_DYNAMIC_SHAPE_SWEEP_NOT_PROMOTED":
    raise SystemExit(f"checkpoint status {c.get('status')}")
expected_check=[3,225,256,320,384,448,479]
got=[r.get("N") for r in c.get("tests",[]) if r.get("status")=="PASS_SHAPE_EXECUTION"]
if got!=expected_check: raise SystemExit(f"checkpoint mismatch {got}")
boundary=c.get("negativeBoundaryTests",[])
if len(boundary)!=2 or not all(r.get("status")=="PASS_REJECTED_OUT_OF_RANGE" for r in boundary):
    raise SystemExit(f"checkpoint boundary proof missing: {boundary}")

rows=[]
for p in sorted((root/"chunks").glob("dynamic-acoustic-shape-sweep-CPU_AND_NE-N*.json")):
    r=json.load(open(p))
    if r.get("status")!="PASS_EXHAUSTIVE_INTEGER_DYNAMIC_SHAPE_SWEEP_NOT_PROMOTED":
        raise SystemExit(f"chunk not PASS: {p} {r.get('status')}")
    rows.extend(r.get("tests",[]))
ns=sorted(r["N"] for r in rows if r.get("status")=="PASS_SHAPE_EXECUTION")
expected=list(range(3,480))
if ns!=expected:
    missing=sorted(set(expected)-set(ns));extra=sorted(set(ns)-set(expected))
    raise SystemExit(f"integer sweep incomplete count={len(ns)} missing={missing[:20]} extra={extra[:20]}")
print("SWEEP_STATUS PASS_FULL_N3_TO_N479_INTEGER_SWEEP")
print("INTEGER_TESTS",len(ns))
print("N_RANGE",ns[0],ns[-1])
PY
}

main() {
  [[ "$(git -C "$ROOT" branch --show-current)" == "$BRANCH" ]] || { echo "ERROR: switch to $BRANCH"; return 2; }
  [[ -x "$PYTHON" ]] || { echo "ERROR: missing dynamic Python $PYTHON"; return 2; }
  command -v swift
  command -v xcrun

  local fixed
  fixed="$(find_fixed_asset_root)" || { echo "ERROR: accepted fixed225 runtime not found"; return 2; }

  if [[ -z "$FAMILY" ]]; then FAMILY="$(find_pass_family)"; fi
  [[ -n "$FAMILY" && -f "$FAMILY/receipt.json" ]] || { echo "ERROR: PASS N3...479 family not found"; return 2; }

  if [[ -z "$SWEEP_DIR" ]]; then SWEEP_DIR="$(find_sweep_dir)"; fi
  [[ -n "$SWEEP_DIR" && -d "$SWEEP_DIR/chunks" ]] || { echo "ERROR: full-range sweep directory not found"; return 2; }

  if [[ -z "$WORK" ]]; then
    for i in $(seq 1 99); do
      candidate="$ROOT/ios/.work/dynamic-acoustic/integration-candidate-v$i"
      if [[ ! -e "$candidate" ]]; then WORK="$candidate"; break; fi
    done
  fi
  [[ -n "$WORK" && ! -e "$WORK" ]] || { echo "ERROR: fresh integration work path required: $WORK"; return 2; }
  mkdir -p "$WORK"

  echo "===== VERIFY PHYSICAL SWEEP ====="
  verify_sweep "$SWEEP_DIR"

  echo "===== SWIFT PACKAGE BUILD + TEST ====="
  swift test --package-path "$ROOT/ios" | tee "$WORK/swift-test.log"

  echo "===== GENERATE MAX STOCHASTIC BUFFERS ====="
  "$PYTHON" "$EXP/generate_dynamic_candidate_buffers.py"     --fixed-runtime "$fixed"     --source-root "$SOURCE"     --model-dir "$MODEL"     --output "$WORK/buffers"     --nmax 479 | tee "$WORK/buffers.log"

  echo "===== BUILD DUAL-ORACLE DYNAMIC CANDIDATE ROOT ====="
  "$PYTHON" "$EXP/build_dynamic_candidate_assets.py"     --family "$FAMILY"     --fixed-runtime "$fixed"     --fixture "$FIXTURE"     --flow-noise-max "$WORK/buffers/flow-noise-max.f32"     --hift-excitation-max "$WORK/buffers/hift-excitation-max.f32"     --hift-excitation-n225-reference "$WORK/buffers/hift-excitation-n225-reference.f32"     --output "$WORK/runtime" | tee "$WORK/candidate-assets.log"

  echo "===== CANDIDATE SUMMARY ====="
  "$PYTHON" - "$WORK/runtime/cosyvoice3_dynamic.json" "$WORK/runtime/dynamic-candidate-receipt.json" <<'PY'
import json,sys
m=json.load(open(sys.argv[1]));r=json.load(open(sys.argv[2]))
print("PROFILE =",m["profile"])
print("DYNAMIC =",m["dynamicAcoustic"])
print("RECEIPT_STATUS =",r["status"])
print("FLOW_PREFIX_EXACT =",r["flowNoiseN225PrefixExact"])
print("HIFT_PREFIX_EXACT =",r["hiftExcitationN225PrefixExact"])
print("PRODUCTION_PROMOTION =",r["productionPromotion"])
assert r["status"]=="PASS_DYNAMIC_CANDIDATE_ASSET_ROOT_BUILT_NOT_PROMOTED"
assert r["flowNoiseN225PrefixExact"] is True
assert r["hiftExcitationN225PrefixExact"] is True
assert r["productionPromotion"] is False
PY

  echo "PASS CANDIDATE_ROOT=$WORK/runtime"
  echo "NEXT: physical public-API smoke must use this candidate root; no release promotion has occurred."
}

main "$@"

# Code purpose: turn completed symbolic/device evidence into an isolated SDK integration candidate with compile/test proof and explicit stochastic-buffer provenance.
# Upstream source: current experiment/ios-dynamic-acoustic SDK, completed physical N3...479 sweep, accepted fixed225 runtime, pinned source/checkpoint and PASS full-range symbolic family.
# Runtime environment: macOS arm64 Swift6/Xcode plus the existing dynamic Python3.11 environment.
# Generated time: 2026-10-04 America/New_York.
# Changes: full-sweep gate, Swift package test gate, max-buffer generation, dual-oracle candidate assembly; never mutates fixed225 assets and never marks production promotion.
