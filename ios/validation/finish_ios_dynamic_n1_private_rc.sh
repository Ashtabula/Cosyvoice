#@title finish_ios_dynamic_n1_private_rc.sh
# Requirement: publish the exact accepted dynamic N1...479 runtime as an immutable private Hugging Face RC, verify exact downloaded bytes, ordinary-fetch it through the SDK catalog path, replay default+reference public APIs on a physical iPhone, then commit only accepted private-RC catalog/evidence. License/public redistribution remain pending.
#!/usr/bin/env bash
set -u -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
BRANCH="${COSYVOICE3_DYNAMIC_RELEASE_BRANCH:-experiment/ios-dynamic-acoustic}"
PROFILE="${COSYVOICE3_ASSET_PROFILE:-ios-dynamic-n1-n479-reference}"
VERSION="${COSYVOICE3_ASSET_VERSION:-0.2.0-rc1}"
REPO_ID="${COSYVOICE3_HF_REPO_ID:-actacomes/CosyVoice-assets}"
SOURCE_ASSETS="${COSYVOICE3_ASSET_ROOT:-$ROOT/.work/dynamic-acoustic/integration-candidate-n1-v4/runtime}"
LOWER_RECEIPT="${COSYVOICE3_N1_EXTENSION_RECEIPT:-$ROOT/experiments/dynamic-acoustic/evidence/lower-bound-n1-extension-20261004-173341-20292/lower-bound-extension-receipt.json}"
SMOKE_RECEIPT="${COSYVOICE3_DYNAMIC_SMOKE_RECEIPT:-$ROOT/validation/evidence/dynamic-public-api-smoke-1791154976/dynamic-public-api-smoke-receipt.json}"
LISTENING_RECEIPT="${COSYVOICE3_DYNAMIC_LISTENING_RECEIPT:-$ROOT/validation/evidence/dynamic_n1_listening_acceptance.json}"
HOST_RECEIPT="${COSYVOICE3_HOST_PARITY_RECEIPT:-$ROOT/.work/reference-release/parity/reference_host_parity_receipt.json}"
REFERENCE_WAV="${COSYVOICE3_REFERENCE_WAV:-}"
REFERENCE_TRANSCRIPT="${COSYVOICE3_REFERENCE_TRANSCRIPT:-}"
PYTHON="$ROOT/.venv-release/bin/python"
RELEASE_ROOT="$ROOT/.work/hf-release/$PROFILE/$VERSION"
UPLOAD_RECEIPT="$ROOT/.work/hf-release/$PROFILE/$VERSION-hf-upload-receipt.json"
DOWNLOAD_ROOT="$ROOT/.work/hf-download-replay/$PROFILE-$VERSION"
DOWNLOADED_RELEASE="$DOWNLOAD_ROOT/$PROFILE/$VERSION"
FETCHED_RUNTIME="$ROOT/.work/hf-fetch-replay/$PROFILE-$VERSION"
WORK_CATALOG="$ROOT/.work/hf-release/$PROFILE/$VERSION-releases.candidate.json"
FINAL_RECEIPT="$ROOT/validation/evidence/dynamic_private_rc.json"
BUNDLE_ID="${COSYVOICE3_DYNAMIC_RC_REPLAY_BUNDLE_ID:-com.actacomes.cosyvoice3.dynamicrcreplay}"

fail(){ printf '[COSYVOICE3-DYNAMIC-RC] ERROR %s\n' "$1"; return 1; }

main(){
    command -v git || return $?
    command -v python3 || return $?
    command -v xcodebuild || return $?
    command -v xcrun || return $?
    [ -n "${DEVICE_ID:-}" ] || { fail "set DEVICE_ID"; return 2; }
    [ -n "${DEVELOPMENT_TEAM:-}" ] || { fail "set DEVELOPMENT_TEAM"; return 2; }
    [ -f "$REFERENCE_WAV" ] || { fail "set COSYVOICE3_REFERENCE_WAV to the local validation reference"; return 2; }
    [ -s "$REFERENCE_TRANSCRIPT" ] || { fail "set COSYVOICE3_REFERENCE_TRANSCRIPT to the matching transcript"; return 2; }
    [ -f "$HOST_RECEIPT" ] || { fail "host parity receipt missing: $HOST_RECEIPT"; return 2; }
    [ "$(git -C "$REPO" branch --show-current)" = "$BRANCH" ] || { fail "wrong branch; expected $BRANCH"; return 2; }
    [ -z "$(git -C "$REPO" status --porcelain --untracked-files=no)" ] || { git -C "$REPO" status --short; fail "tracked worktree must be clean"; return 2; }
    git -C "$REPO" pull --ff-only origin "$BRANCH" || return $?

    if [ ! -x "$PYTHON" ]; then python3 -m venv "$ROOT/.venv-release" || return $?; fi
    "$PYTHON" -m pip install -r "$ROOT/requirements-release.txt" || return $?
    "$PYTHON" - <<'PY' || return $?
from huggingface_hub import HfApi
x=HfApi().whoami()
name=(x.get("name") or x.get("fullname") or "") if isinstance(x,dict) else ""
print("[COSYVOICE3-DYNAMIC-RC] HF identity="+repr(name),flush=True)
if name!="actacomes": raise SystemExit("Hugging Face login must be actacomes")
PY

    printf '[COSYVOICE3-DYNAMIC-RC] STEP 1/7 stage and upload private RC\n'
    rm -rf "$RELEASE_ROOT"
    "$PYTHON" "$ROOT/tools/publish_huggingface_ios_dynamic_n1.py" \
        --version "$VERSION" --repo-id "$REPO_ID" --source-assets "$SOURCE_ASSETS" \
        --lower-bound-receipt "$LOWER_RECEIPT" --smoke-receipt "$SMOKE_RECEIPT" \
        --listening-receipt "$LISTENING_RECEIPT" --upload || return $?
    [ -s "$UPLOAD_RECEIPT" ] || { fail "upload receipt missing: $UPLOAD_RECEIPT"; return 3; }

    printf '[COSYVOICE3-DYNAMIC-RC] STEP 2/7 download exact immutable revision and verify payload\n'
    rm -rf "$DOWNLOAD_ROOT"; mkdir -p "$DOWNLOAD_ROOT"
    "$PYTHON" - "$UPLOAD_RECEIPT" "$DOWNLOAD_ROOT" <<'PY' || return $?
import hashlib,json,sys
from pathlib import Path
from huggingface_hub import snapshot_download
r=json.loads(Path(sys.argv[1]).read_text()); root=Path(sys.argv[2])
snapshot_download(repo_id=r["repoId"],repo_type="model",revision=r["commit"],allow_patterns=[f'{r["pathInRepo"]}/**'],local_dir=root)
release=root/r["pathInRepo"]; m=json.loads((release/"asset-manifest.json").read_text())
rows=[]
for row in m["files"]:
 p=release/row["path"]
 h=hashlib.sha256()
 with p.open("rb") as f:
  for b in iter(lambda:f.read(8*1024*1024),b""): h.update(b)
 if p.stat().st_size!=int(row["bytes"]) or h.hexdigest()!=row["sha256"]: raise SystemExit(f"download mismatch {row['path']}")
 rows.append(row)
tree=hashlib.sha256()
for row in sorted(rows,key=lambda x:x["path"]):
 tree.update(row["path"].encode());tree.update(b"\0");tree.update(str(int(row["bytes"])).encode());tree.update(b"\0");tree.update(row["sha256"].encode());tree.update(b"\n")
if tree.hexdigest()!=m["payloadTreeSha256"] or tree.hexdigest()!=r["payloadTreeSha256"]: raise SystemExit("payload tree mismatch")
print("[COSYVOICE3-DYNAMIC-RC] IMMUTABLE_DOWNLOAD_PASS revision="+r["commit"]+" tree="+tree.hexdigest(),flush=True)
PY
    "$PYTHON" "$ROOT/assets/validate_assets.py" --root "$DOWNLOADED_RELEASE" --require-reference || return $?

    printf '[COSYVOICE3-DYNAMIC-RC] STEP 3/7 build temporary catalog entry\n'
    cp "$ROOT/assets/releases.json" "$WORK_CATALOG" || return $?
    "$PYTHON" - "$WORK_CATALOG" "$UPLOAD_RECEIPT" "$DOWNLOADED_RELEASE/asset-manifest.json" <<'PY' || return $?
import json,sys
from pathlib import Path
p=Path(sys.argv[1]); c=json.loads(p.read_text()); u=json.loads(Path(sys.argv[2]).read_text()); m=json.loads(Path(sys.argv[3]).read_text())
entry={
 "assetTechnicalStatus":"READY_PRIVATE_RC",
 "candidateTechnicalDistributionReady":False,
 "distributionStatus":"PRIVATE_RC",
 "licenseGate":m["licenseGate"],
 "minimumIOS":m["minimumIOS"],
 "pathInRepo":u["pathInRepo"],
 "payloadTreeSha256":m["payloadTreeSha256"],
 "profile":m["profile"],
 "publicRedistributionApproved":False,
 "publicReleaseStatus":"PENDING",
 "referenceStatus":m["referenceStatus"],
 "repoId":u["repoId"],
 "repoType":"model",
 "requiresAuthentication":True,
 "revision":u["commit"],
 "runtimeProfile":m["runtimeProfile"],
 "sdkIntegrationReady":True,
 "sdkReleaseStatus":"PRIVATE_RC_ENGINEERING_ACCEPTED",
 "tag":u["tag"],
 "testedRuntimeTreeSha256":m["testedRuntimeTreeSha256"],
 "validatedRuntimeSourceCommit":m["validatedRuntimeSourceCommit"],
 "version":m["assetVersion"]
}
rows=[x for x in c.get("releases",[]) if not (x.get("profile")==entry["profile"] and x.get("version")==entry["version"])]
rows.append(entry); c["releases"]=rows
p.write_text(json.dumps(c,indent=2,sort_keys=True)+"\n")
print("[COSYVOICE3-DYNAMIC-RC] TEMP_CATALOG_PASS "+json.dumps(entry,sort_keys=True),flush=True)
PY

    printf '[COSYVOICE3-DYNAMIC-RC] STEP 4/7 ordinary SDK immutable fetch\n'
    rm -rf "$FETCHED_RUNTIME"
    "$PYTHON" "$ROOT/assets/fetch_assets.py" --catalog "$WORK_CATALOG" --profile "$PROFILE" --version "$VERSION" --output "$FETCHED_RUNTIME" --force || return $?

    printf '[COSYVOICE3-DYNAMIC-RC] STEP 5/7 physical public-API replay from fetched RC\n'
    COSYVOICE3_ASSET_ROOT="$FETCHED_RUNTIME" \
    COSYVOICE3_DYNAMIC_PUBLIC_API_SMOKE=1 \
    COSYVOICE3_PROMOTED_RUNTIME_MODE=1 \
    COSYVOICE3_FRESH_INSTALL=1 \
    COSYVOICE3_HOST_PARITY_RECEIPT="$HOST_RECEIPT" \
    COSYVOICE3_REFERENCE_WAV="$REFERENCE_WAV" \
    COSYVOICE3_REFERENCE_TRANSCRIPT="$REFERENCE_TRANSCRIPT" \
    COSYVOICE3_PYTHON="$PYTHON" CONFIGURATION=Release BUNDLE_ID="$BUNDLE_ID" \
    bash "$ROOT/validation/install_device_smoke.sh" || return $?

    printf '[COSYVOICE3-DYNAMIC-RC] STEP 6/7 record immutable fetch/replay evidence\n'
    local evidence
    evidence="$(ls -dt "$ROOT"/validation/evidence/dynamic-public-api-smoke-* | head -n 1)" || return $?
    "$PYTHON" - "$UPLOAD_RECEIPT" "$DOWNLOADED_RELEASE/asset-manifest.json" "$evidence/dynamic-public-api-smoke-receipt.json" "$FINAL_RECEIPT" <<'PY' || return $?
import json,sys,time
from pathlib import Path
u=json.loads(Path(sys.argv[1]).read_text());m=json.loads(Path(sys.argv[2]).read_text());d=json.loads(Path(sys.argv[3]).read_text())
if d.get("status")!="PASS_DYNAMIC_PUBLIC_API_DEFAULT_AND_REFERENCE": raise SystemExit("RC replay is not PASS")
if d.get("profile")!="ios18-dynamic-n1-n479-candidate" or d.get("speechTokenBounds")!=[1,479]: raise SystemExit("RC replay profile/bounds mismatch")
out={
 "schemaVersion":1,"status":"PASS_DYNAMIC_PRIVATE_RC_IMMUTABLE_REPLAY",
 "profile":m["profile"],"version":m["assetVersion"],"repoId":u["repoId"],"revision":u["commit"],"tag":u["tag"],
 "visibility":"private","payloadTreeSha256":m["payloadTreeSha256"],"testedRuntimeTreeSha256":m["testedRuntimeTreeSha256"],
 "validatedRuntimeSourceCommit":m["validatedRuntimeSourceCommit"],"ordinaryDeveloperFetchPass":True,
 "publicApiDefaultReplayPass":True,"publicApiReferenceReplayPass":True,
 "device":{"model":d.get("device"),"modelIdentifier":d.get("deviceModelIdentifier"),"systemVersion":d.get("systemVersion")},
 "default":{"N":d["default"]["inferredSpeechTokensFromPCM"],"samples":d["default"]["samples"]},
 "reference":{"N":d["reference"]["inferredSpeechTokensFromPCM"],"samples":d["reference"]["samples"]},
 "licenseGate":m["licenseGate"],"publicRedistributionApproved":False,"recordedAtUnix":int(time.time())
}
Path(sys.argv[4]).parent.mkdir(parents=True,exist_ok=True);Path(sys.argv[4]).write_text(json.dumps(out,indent=2,sort_keys=True)+"\n")
print("[COSYVOICE3-DYNAMIC-RC] REPLAY_PASS "+json.dumps(out,sort_keys=True),flush=True)
PY

    printf '[COSYVOICE3-DYNAMIC-RC] STEP 7/7 accept catalog row and push release metadata\n'
    cp "$WORK_CATALOG" "$ROOT/assets/releases.json" || return $?
    git -C "$REPO" add ios/assets/releases.json ios/validation/evidence/dynamic_private_rc.json || return $?
    git -C "$REPO" -c user.name="actacomes" -c user.email="developer@actacomes.com" commit -m "release(ios): register dynamic N1 private RC" || return $?
    git -C "$REPO" push origin "$BRANCH" || return $?
    printf '[COSYVOICE3-DYNAMIC-RC] COMPLETE profile=%s version=%s head=%s license=PENDING public=false\n' "$PROFILE" "$VERSION" "$(git -C "$REPO" rev-parse HEAD)"
}
main "$@"
RC=$?
printf '[COSYVOICE3-DYNAMIC-RC] rc=%s\n' "$RC"
test "$RC" -eq 0

# Code purpose: one-command immutable private RC publication/fetch/physical replay/catalog registration for the accepted dynamic N1...479 iOS runtime.
# Upstream source: dynamic N1 publisher, lower-bound/public-API/listening evidence, ordinary fetch/validation and physical DeviceSmoke public API.
# Runtime environment: canonical macOS Apple-Silicon release host, authenticated actacomes Hugging Face, Xcode, connected physical iPhone.
# Generated time: 2026-10-04 America/New_York.
# Changes: new dynamic RC closure; raw validation reference files are never uploaded and license/public redistribution remain pending.
