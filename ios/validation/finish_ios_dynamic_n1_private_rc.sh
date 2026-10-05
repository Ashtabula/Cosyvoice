#!/usr/bin/env bash
#@title finish_ios_dynamic_n1_private_rc.sh
# Requirement: publish the exact accepted dynamic N1...479 runtime as an immutable private Hugging Face RC, verify exact downloaded bytes, ordinary-fetch it through the SDK catalog path, replay default+reference public APIs on a physical iPhone, then commit only accepted private-RC catalog/evidence. License/public redistribution remain pending.
set -u -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
BRANCH="${COSYVOICE3_DYNAMIC_RELEASE_BRANCH:-experiment/ios-dynamic-acoustic}"
PROFILE="${COSYVOICE3_ASSET_PROFILE:-ios-dynamic-n1-n479-reference}"
VERSION="${COSYVOICE3_ASSET_VERSION:-0.2.0-rc1}"
REPO_ID="${COSYVOICE3_HF_REPO_ID:-actacomes/CosyVoice-assets}"
SOURCE_ASSETS="${COSYVOICE3_ASSET_ROOT:-$ROOT/.work/dynamic-acoustic/integration-candidate-n1-v4/runtime}"
LOWER_RECEIPT="${COSYVOICE3_N1_EXTENSION_RECEIPT:-$ROOT/experiments/dynamic-acoustic/evidence/lower-bound-n1-extension-20261004-173341-20292/lower-bound-extension-receipt.json}"
SMOKE_RECEIPT="${COSYVOICE3_DYNAMIC_SMOKE_RECEIPT:-$ROOT/validation/evidence/dynamic_n1_public_api_smoke.json}"
LISTENING_RECEIPT="${COSYVOICE3_DYNAMIC_LISTENING_RECEIPT:-$ROOT/validation/evidence/dynamic_n1_listening_acceptance.json}"
HOST_RECEIPT="${COSYVOICE3_HOST_PARITY_RECEIPT:-$ROOT/.work/reference-release/parity/reference_host_parity_receipt.json}"
REFERENCE_WAV="${COSYVOICE3_REFERENCE_WAV:-}"
REFERENCE_TRANSCRIPT="${COSYVOICE3_REFERENCE_TRANSCRIPT:-}"
PYTHON="$ROOT/.venv-release/bin/python"
DYNAMIC_PYTHON="${COSYVOICE3_DYNAMIC_PYTHON:-$ROOT/.work/dynamic-acoustic/venv/bin/python}"
CONVERSION_RECEIPT="$ROOT/validation/evidence/dynamic_conversion_provenance.json"
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
    if [ -z "${DEVICE_ID:-}" ]; then
        local destinations
        destinations="$(xcodebuild -project "$ROOT/validation/DeviceSmoke/CosyVoice3DeviceSmoke.xcodeproj" -scheme CosyVoice3DeviceSmoke -showdestinations 2>&1)"
        DEVICE_ID="$(printf '%s\n' "$destinations" | sed -n 's/.*{ platform:iOS, arch:arm64, id:\([^,}]*\), name:.*/\1/p' | head -n 1 | xargs)"
        [ -n "$DEVICE_ID" ] || { printf '%s\n' "$destinations"; fail "no available physical iPhone destination"; return 2; }
        export DEVICE_ID
        printf '[COSYVOICE3-DYNAMIC-RC] auto-selected physical iPhone device=%s\n' "$DEVICE_ID"
    fi
    [ -n "${DEVELOPMENT_TEAM:-}" ] || { fail "set DEVELOPMENT_TEAM"; return 2; }
    local reuse_input_dir="$ROOT/.work/device-smoke-reused-input"
    mkdir -p "$reuse_input_dir"
    if [ -z "$REFERENCE_WAV" ] && [ -f "$ROOT/validation/DeviceSmoke/GeneratedAssets/reference.wav" ]; then cp "$ROOT/validation/DeviceSmoke/GeneratedAssets/reference.wav" "$reuse_input_dir/reference.wav" || return $?; REFERENCE_WAV="$reuse_input_dir/reference.wav"; fi
    if [ -z "$REFERENCE_TRANSCRIPT" ] && [ -s "$ROOT/validation/DeviceSmoke/GeneratedAssets/reference.txt" ]; then cp "$ROOT/validation/DeviceSmoke/GeneratedAssets/reference.txt" "$reuse_input_dir/reference.txt" || return $?; REFERENCE_TRANSCRIPT="$reuse_input_dir/reference.txt"; fi
    if [ ! -f "$HOST_RECEIPT" ] && [ -f "$ROOT/validation/DeviceSmoke/GeneratedAssets/reference_host_parity_receipt.json" ]; then cp "$ROOT/validation/DeviceSmoke/GeneratedAssets/reference_host_parity_receipt.json" "$reuse_input_dir/reference_host_parity_receipt.json" || return $?; HOST_RECEIPT="$reuse_input_dir/reference_host_parity_receipt.json"; fi
    [ -f "$REFERENCE_WAV" ] || { fail "reference WAV unavailable; set COSYVOICE3_REFERENCE_WAV or retain DeviceSmoke/GeneratedAssets/reference.wav"; return 2; }
    [ -s "$REFERENCE_TRANSCRIPT" ] || { fail "reference transcript unavailable; set COSYVOICE3_REFERENCE_TRANSCRIPT or retain DeviceSmoke/GeneratedAssets/reference.txt"; return 2; }
    [ -f "$HOST_RECEIPT" ] || { fail "host parity receipt unavailable at explicit/default or DeviceSmoke staged path"; return 2; }
    [ -x "$DYNAMIC_PYTHON" ] || { fail "dynamic conversion Python missing: $DYNAMIC_PYTHON"; return 2; }
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

    printf '[COSYVOICE3-DYNAMIC-RC] STEP 1/7 record exact conversion provenance; stage and upload/reuse private RC\n'
    "$DYNAMIC_PYTHON" "$ROOT/validation/record_dynamic_conversion_provenance.py" --output "$CONVERSION_RECEIPT" || return $?
    rm -rf "$RELEASE_ROOT"
    "$PYTHON" "$ROOT/tools/publish_huggingface_ios_dynamic_n1.py" \
        --version "$VERSION" --repo-id "$REPO_ID" --source-assets "$SOURCE_ASSETS" \
        --lower-bound-receipt "$LOWER_RECEIPT" --conversion-provenance-receipt "$CONVERSION_RECEIPT" --smoke-receipt "$SMOKE_RECEIPT" \
        --listening-receipt "$LISTENING_RECEIPT" || return $?
    local reuse_upload=0
    if [ -s "$UPLOAD_RECEIPT" ]; then
        if "$PYTHON" - "$UPLOAD_RECEIPT" "$RELEASE_ROOT/asset-manifest.json" "$VERSION" "$REPO_ID" <<'PY'
import json,re,sys
from pathlib import Path
r=json.loads(Path(sys.argv[1]).read_text());m=json.loads(Path(sys.argv[2]).read_text())
ok=(r.get("status")=="PASS" and r.get("version")==sys.argv[3] and r.get("repoId")==sys.argv[4]
    and r.get("profile")==m.get("profile") and r.get("payloadTreeSha256")==m.get("payloadTreeSha256")
    and r.get("testedRuntimeTreeSha256")==m.get("testedRuntimeTreeSha256")
    and r.get("visibility")=="private" and re.fullmatch(r"[0-9a-f]{40}",str(r.get("commit") or "")))
print("[COSYVOICE3-DYNAMIC-RC] existing upload receipt "+("REUSE_PASS" if ok else "STALE"),flush=True)
raise SystemExit(0 if ok else 1)
PY
        then reuse_upload=1; fi
    fi
    if [ "$reuse_upload" -ne 1 ]; then
        "$PYTHON" "$ROOT/tools/publish_huggingface_ios_dynamic_n1.py" \
            --version "$VERSION" --repo-id "$REPO_ID" --source-assets "$SOURCE_ASSETS" \
            --lower-bound-receipt "$LOWER_RECEIPT" --conversion-provenance-receipt "$CONVERSION_RECEIPT" --smoke-receipt "$SMOKE_RECEIPT" \
            --listening-receipt "$LISTENING_RECEIPT" --upload || return $?
    fi
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
 "validatedRuntimeSourceCommit":m["validatedRuntimeSourceCommit"],"conversionProvenance":m.get("conversionProvenance"),"ordinaryDeveloperFetchPass":True,
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
    git -C "$REPO" add ios/assets/releases.json ios/validation/evidence/dynamic_private_rc.json ios/validation/evidence/dynamic_conversion_provenance.json || return $?
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

# Changes 2026-10-04: private-RC closure is rerun-safe after partial failures: stage first, reuse an existing private upload receipt only when exact payload/runtime-tree/profile/version/repo hashes match, otherwise upload a new RC.

# Changes 2026-10-04: immutable private-RC evidence carries the asset manifest's historical conversion provenance so Candidate environment receipts can distinguish it from clean-room build/consumer requirements.

# Changes 2026-10-04: private RC closure records exact package-metadata-derived conversion provenance with the dynamic coremltools/torch environment before staging, passes that receipt into the publisher, and commits the sanitized provenance evidence with the private RC receipt.

# Changes 2026-10-04: use committed sanitized dynamic N1 public-API smoke evidence instead of an untracked timestamped smoke directory; auto-detect the physical iPhone and reuse staged reference/host inputs during preflight.

# Changes 2026-10-04: when falling back to previously staged reference/host inputs, copy them into ios/.work/device-smoke-reused-input before any GeneratedAssets replacement so physical RC replay cannot delete its own source files.
