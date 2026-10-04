#!/bin/bash
set -euo pipefail

# Requirement: build the exact lower-bound-gated N1...479 integration candidate, then run the physical default+custom-reference public CosyVoice3Engine.synthesize() smoke against that exact candidate root. Preserve productionPromotion=false and return the shell prompt normally.
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
EXP="$ROOT/ios/experiments/dynamic-acoustic"
BRANCH="experiment/ios-dynamic-acoustic"
BUILD_SCRIPT="$EXP/build_n1_dynamic_candidate.sh"
SMOKE_SCRIPT="$ROOT/ios/validation/install_device_smoke.sh"
WORK="${COSYVOICE3_N1_INTEGRATION_WORK:-}"
: "${DEVELOPMENT_TEAM:?export DEVELOPMENT_TEAM=<Apple-development-team-id>}"

[[ "$(git -C "$ROOT" branch --show-current)" == "$BRANCH" ]] || { echo "ERROR: switch to $BRANCH"; exit 2; }
command -v git
command -v python3
command -v xcodebuild
command -v xcrun

if [[ -z "$WORK" ]]; then
  for i in $(seq 1 99); do
    candidate="$ROOT/ios/.work/dynamic-acoustic/integration-candidate-n1-v$i"
    if [[ ! -e "$candidate" ]]; then WORK="$candidate";break;fi
  done
fi
[[ -n "$WORK" && ! -e "$WORK" ]] || { echo "ERROR: fresh N1 integration work path required: $WORK";exit 2; }

SOURCE_COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
echo "===== BUILD EXACT N1...479 CANDIDATE ====="
echo "SOURCE_COMMIT=$SOURCE_COMMIT"
COSYVOICE3_N1_INTEGRATION_WORK="$WORK" bash "$BUILD_SCRIPT" | tee "$ROOT/ios/.work/dynamic-acoustic/n1-candidate-build-$(basename "$WORK").log"

RUNTIME="$WORK/runtime"
[[ -f "$RUNTIME/cosyvoice3_dynamic.json" && -f "$RUNTIME/dynamic-candidate-receipt.json" ]] || {
  echo "ERROR: N1 candidate runtime not materialized at $RUNTIME";exit 3;
}

echo "===== VERIFY EXACT N1 CANDIDATE BEFORE DEVICE STAGING ====="
python3 - "$RUNTIME/cosyvoice3_dynamic.json" "$RUNTIME/dynamic-candidate-receipt.json" "$SOURCE_COMMIT" <<'PY'
import json,sys
m=json.load(open(sys.argv[1]));r=json.load(open(sys.argv[2]));head=sys.argv[3]
assert m["profile"]=="ios18-dynamic-n1-n479-candidate",m.get("profile")
assert m["dynamicAcoustic"]["speechTokenMinimum"]==1
assert m["dynamicAcoustic"]["speechTokenMaximum"]==479
assert r["status"]=="PASS_DYNAMIC_CANDIDATE_ASSET_ROOT_BUILT_NOT_PROMOTED",r.get("status")
assert r["NBounds"]==[1,479],r.get("NBounds")
assert r["lowerBoundPhysicalExtensionStatus"]=="PASS_N1_N2_LOWER_BOUND_EXTENSION_NOT_PROMOTED",r.get("lowerBoundPhysicalExtensionStatus")
assert r["productionPromotion"] is False
print("CANDIDATE_PROFILE",m["profile"])
print("CANDIDATE_N_BOUNDS",r["NBounds"])
print("LOWER_BOUND_GATE",r["lowerBoundPhysicalExtensionStatus"])
print("SOURCE_HEAD",head)
PY

echo "===== RUN PHYSICAL PUBLIC-API DEFAULT + REFERENCE SMOKE ====="
BEFORE="$(date +%s)"
COSYVOICE3_ASSET_ROOT="$RUNTIME" COSYVOICE3_DYNAMIC_PUBLIC_API_SMOKE=1 COSYVOICE3_PROMOTED_RUNTIME_MODE=0 COSYVOICE3_FRESH_INSTALL=1 bash "$SMOKE_SCRIPT"

echo "===== LOCATE AND VERIFY NEW SMOKE EVIDENCE ====="
EVIDENCE="$(python3 - "$ROOT/ios/validation/evidence" "$BEFORE" "$SOURCE_COMMIT" <<'PY'
import json,pathlib,sys
root=pathlib.Path(sys.argv[1]);before=int(sys.argv[2]);head=sys.argv[3]
rows=[]
for p in root.glob("dynamic-public-api-smoke-*"):
    receipt=p/"dynamic-public-api-smoke-receipt.json"
    if not receipt.is_file(): continue
    try:
        r=json.load(open(receipt))
        if int(p.name.rsplit("-",1)[-1]) < before: continue
        if r.get("status")!="PASS_DYNAMIC_PUBLIC_API_DEFAULT_AND_REFERENCE": continue
        if r.get("sourceCommit")!=head: continue
        if r.get("profile")!="ios18-dynamic-n1-n479-candidate": continue
        if r.get("speechTokenBounds")!=[1,479]: continue
        rows.append((receipt.stat().st_mtime,p))
    except Exception: pass
if not rows: raise SystemExit("no exact N1 candidate PASS smoke evidence found")
print(max(rows)[1])
PY
)"
RECEIPT="$EVIDENCE/dynamic-public-api-smoke-receipt.json"
DEFAULT_WAV="$EVIDENCE/dynamic-default.wav"
REFERENCE_WAV="$EVIDENCE/dynamic-reference.wav"

python3 - "$RECEIPT" "$DEFAULT_WAV" "$REFERENCE_WAV" <<'PY'
import hashlib,json,pathlib,sys,wave
receipt,default_wav,reference_wav=map(pathlib.Path,sys.argv[1:])
def sha(p):
 h=hashlib.sha256()
 with open(p,"rb") as f:
  for b in iter(lambda:f.read(8*1024*1024),b""):h.update(b)
 return h.hexdigest()
r=json.load(open(receipt))
assert r["status"]=="PASS_DYNAMIC_PUBLIC_API_DEFAULT_AND_REFERENCE"
assert r["profile"]=="ios18-dynamic-n1-n479-candidate"
assert r["speechTokenBounds"]==[1,479]
assert r["productionPromotion"] is False
for lane,p in (("default",default_wav),("reference",reference_wav)):
 assert p.is_file(),p
 n=int(r[lane]["inferredSpeechTokensFromPCM"]);samples=int(r[lane]["samples"])
 assert 1<=n<=479,(lane,n)
 assert samples==960*n,(lane,samples,n)
 assert sha(p)==r[lane]["wavSha256"],(lane,sha(p),r[lane]["wavSha256"])
 with wave.open(str(p),"rb") as w:
  assert w.getnchannels()==1 and w.getframerate()==24000 and w.getnframes()==samples,(lane,w.getparams())
 print(lane.upper(),"N",n,"SAMPLES",samples,"DURATION_SECONDS",samples/24000.0,"WAV_SHA256",sha(p))
print("PASS_N1_CANDIDATE_PUBLIC_API_DEFAULT_AND_REFERENCE")
PY

cat >"$WORK/public-api-smoke-pointer.txt" <<EOF
sourceCommit=$SOURCE_COMMIT
candidateRoot=$RUNTIME
evidence=$EVIDENCE
receipt=$RECEIPT
defaultWav=$DEFAULT_WAV
referenceWav=$REFERENCE_WAV
productionPromotion=false
EOF

echo "PASS_N1_CANDIDATE_PUBLIC_API_DEFAULT_AND_REFERENCE"
echo "CANDIDATE_ROOT=$RUNTIME"
echo "EVIDENCE=$EVIDENCE"
echo "NEXT: listen to both WAVs; only then run record_dynamic_listening_acceptance.py with explicit ACCEPT/REJECT decisions."

# Code purpose: one foreground command to build the exact physically lower-bound-gated N1...479 candidate and prove the real public SDK default/reference synthesis paths on a physical iPhone.
# Upstream source: PASS_N1_N2_LOWER_BOUND_EXTENSION_NOT_PROMOTED evidence, build_n1_dynamic_candidate.sh, install_device_smoke.sh and current experiment/ios-dynamic-acoustic source HEAD.
# Runtime environment: macOS arm64 Swift6/Xcode/xcrun, connected signed physical iPhone, existing validated reference inputs.
# Generated time: 2026-10-04 America/New_York.
# Changes: new exact-candidate build+device-smoke orchestration, source/profile/bounds/WAV-hash fail-closed verification, no background process and no production promotion.

# Changes 2026-10-04: force a fresh DeviceSmoke install for the large dynamic runtime, reclaiming the prior app/container before iOS install staging so replacement does not transiently require storage for two full copies.
