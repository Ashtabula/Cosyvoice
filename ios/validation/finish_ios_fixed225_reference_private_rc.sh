#@title finish_ios_fixed225_reference_private_rc.sh
# Requirement: publish the complete device-promoted CosyVoice3 fixed225-reference runtime as an immutable private Hugging Face RC, verify the exact uploaded commit, register it in releases.json, fetch it through the ordinary-developer path, physically replay that fetched runtime through the public API, then commit/push only accepted release metadata.
#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE="ios-fixed225-reference"
VERSION="${COSYVOICE3_ASSET_VERSION:-0.1.0-rc1}"
REPO_ID="${COSYVOICE3_HF_REPO_ID:-actacomes/CosyVoice-assets}"
ASSET_ROOT="${COSYVOICE3_ASSET_ROOT:-$ROOT/.work/device-runtime}"
HOST_RECEIPT="${COSYVOICE3_HOST_PARITY_RECEIPT:-$ROOT/.work/reference-release/parity/reference_host_parity_receipt.json}"
DEVICE_RECEIPT="$ROOT/validation/reference-device/reference-smoke-receipt.json"
PROMOTION_RECEIPT="$ROOT/validation/reference-device/promotion-receipt.json"
REFERENCE_WAV="${COSYVOICE3_REFERENCE_WAV:-/Volumes/WD/Codes/dub/dub_ios/ios/ExpressionHeadToHead/GeneratedAssets/leijun-1.wav}"
REFERENCE_TRANSCRIPT="${COSYVOICE3_REFERENCE_TRANSCRIPT:-/Volumes/WD/Codes/dub/dub_ios/ios/ExpressionHeadToHead/GeneratedAssets/leijun-1.txt}"
DEVICE_ID="${DEVICE_ID:-00008150-000A05CA1440401C}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-H5R282PV62}"
EXPECTED_BRANCH="${COSYVOICE3_RELEASE_BRANCH:-release/ios-fixed225-sdk-ready}"
PYTHON="$ROOT/.venv-release/bin/python"

RELEASE_ROOT="$ROOT/.work/hf-release/$PROFILE/$VERSION"
UPLOAD_RECEIPT="$ROOT/.work/hf-release/$PROFILE/$VERSION-hf-upload-receipt.json"
DOWNLOAD_ROOT="$ROOT/.work/hf-download-replay/$VERSION"
DOWNLOADED_RELEASE="$DOWNLOAD_ROOT/$PROFILE/$VERSION"
FETCHED_RUNTIME="$ROOT/.work/hf-fetch-replay/$VERSION"
REPLAY_RECEIPT="$ROOT/.work/hf-fetch-replay/$VERSION-device-receipt.json"
FINAL_RECEIPT="$ROOT/.work/hf-fetch-replay/$VERSION-private-rc-receipt.json"
WORK_CATALOG="$ROOT/.work/hf-release/$PROFILE/$VERSION-releases.candidate.json"
REPLAY_BUNDLE_ID="com.actacomes.cosyvoice3.hfreplay"

fail() {
    printf '[COSYVOICE3-HF-FINISH] ERROR %s\n' "$1"
    return 1
}

ensure_clean_checkout() {
    local branch status
    branch="$(git -C "$ROOT/.." branch --show-current)" || return $?
    [ "$branch" = "$EXPECTED_BRANCH" ] || {
        fail "release workflow must run on $EXPECTED_BRANCH; observed $branch"
        return 1
    }
    status="$(git -C "$ROOT/.." status --porcelain --untracked-files=no)" || return $?
    if [ -n "$status" ]; then
        printf '%s\n' "$status"
        fail "tracked worktree must be clean before private-RC workflow"
        return 1
    fi
    printf '[COSYVOICE3-HF-FINISH] source branch=%s head=%s\n' "$branch" "$(git -C "$ROOT/.." rev-parse HEAD)"
}

ensure_release_python_and_hf_identity() {
    if [ ! -x "$PYTHON" ]; then
        python3 -m venv "$ROOT/.venv-release" || return $?
    fi
    "$PYTHON" -m pip install -r "$ROOT/requirements-release.txt" || return $?
    "$PYTHON" - "$REPO_ID" <<'PY'
import sys
from huggingface_hub import HfApi
from huggingface_hub.errors import LocalTokenNotFoundError
repo_id=sys.argv[1]
try:
    identity=HfApi().whoami()
except LocalTokenNotFoundError:
    raise SystemExit("[COSYVOICE3-HF-FINISH] Hugging Face token not found. Run: ios/.venv-release/bin/hf auth login")
name=(identity.get("name") or identity.get("fullname") or "") if isinstance(identity,dict) else (getattr(identity,"name","") or getattr(identity,"fullname",""))
print(f"[COSYVOICE3-HF-FINISH] HF identity={name!r} target={repo_id}",flush=True)
if name!="actacomes":
    raise SystemExit("[COSYVOICE3-HF-FINISH] Hugging Face login must be actacomes. Run ios/.venv-release/bin/hf auth login and rerun.")
PY
}

validate_canonical_runtime() {
    printf '\n[COSYVOICE3-HF-FINISH] STEP 1/8 validate canonical device-promoted runtime\n'
    "$PYTHON" "$ROOT/assets/validate_assets.py" --root "$ASSET_ROOT" --require-reference || return $?
    "$PYTHON" - "$ROOT/manifest.json" "$PROMOTION_RECEIPT" <<'PY'
import json,sys
from pathlib import Path
m=json.loads(Path(sys.argv[1]).read_text());p=json.loads(Path(sys.argv[2]).read_text())
if m.get("publicApi",{}).get("customReferencePromoted") is not True:
    raise SystemExit("[COSYVOICE3-HF-FINISH] publication customReferencePromoted is not true")
if m.get("fixed225Profile",{}).get("customReference",{}).get("status")!="PASS_DEVICE_PARITY":
    raise SystemExit("[COSYVOICE3-HF-FINISH] publication custom-reference status is not PASS_DEVICE_PARITY")
if p.get("status")!="PASS_CUSTOM_REFERENCE_DEVICE_PROMOTION":
    raise SystemExit("[COSYVOICE3-HF-FINISH] promotion receipt is not PASS")
print("[COSYVOICE3-HF-FINISH] CANONICAL_RUNTIME_PASS",flush=True)
PY
}

prepare_release() {
    printf '\n[COSYVOICE3-HF-FINISH] STEP 2/8 prepare exact private-RC payload\n'
    rm -rf "$RELEASE_ROOT"
    "$PYTHON" "$ROOT/tools/publish_huggingface_ios_fixed225_reference.py"         --version "$VERSION"         --repo-id "$REPO_ID"         --source-assets "$ASSET_ROOT"         --host-receipt "$HOST_RECEIPT"         --device-receipt "$DEVICE_RECEIPT"         --promotion-receipt "$PROMOTION_RECEIPT" || return $?
    [ -f "$RELEASE_ROOT/asset-manifest.json" ] || {
        fail "prepare-only asset-manifest.json missing"
        return 1
    }
}

upload_private_rc() {
    printf '\n[COSYVOICE3-HF-FINISH] STEP 3/8 upload private Hugging Face RC\n'
    if [ -f "$UPLOAD_RECEIPT" ]; then
        if "$PYTHON" - "$UPLOAD_RECEIPT" "$VERSION" "$REPO_ID" <<'PY'
import json,sys
from pathlib import Path
r=json.loads(Path(sys.argv[1]).read_text())
ok=(r.get("status")=="PASS" and r.get("version")==sys.argv[2] and r.get("repoId")==sys.argv[3]
    and r.get("visibility")=="private" and len(str(r.get("commit") or ""))==40)
print("[COSYVOICE3-HF-FINISH] existing upload receipt "+("PASS" if ok else "INVALID"),flush=True)
raise SystemExit(0 if ok else 1)
PY
        then
            printf '[COSYVOICE3-HF-FINISH] reusing existing upload receipt %s\n' "$UPLOAD_RECEIPT"
            return 0
        fi
    fi

    "$PYTHON" "$ROOT/tools/publish_huggingface_ios_fixed225_reference.py"         --version "$VERSION"         --repo-id "$REPO_ID"         --source-assets "$ASSET_ROOT"         --host-receipt "$HOST_RECEIPT"         --device-receipt "$DEVICE_RECEIPT"         --promotion-receipt "$PROMOTION_RECEIPT"         --upload || return $?
    [ -f "$UPLOAD_RECEIPT" ] || {
        fail "HF upload receipt missing after upload"
        return 1
    }
}

download_and_verify_immutable_commit() {
    printf '\n[COSYVOICE3-HF-FINISH] STEP 4/8 download exact immutable HF commit and verify bytes\n'
    rm -rf "$DOWNLOAD_ROOT"
    mkdir -p "$DOWNLOAD_ROOT"
    "$PYTHON" - "$UPLOAD_RECEIPT" "$DOWNLOAD_ROOT" <<'PY'
import hashlib,json,sys
from pathlib import Path
from huggingface_hub import snapshot_download
receipt=json.loads(Path(sys.argv[1]).read_text());dest=Path(sys.argv[2]).resolve()
repo=receipt["repoId"];revision=receipt["commit"];profile=receipt["profile"];version=receipt["version"]
snapshot_download(repo_id=repo,repo_type="model",revision=revision,allow_patterns=[f"{profile}/{version}/**"],local_dir=dest)
release=dest/profile/version
manifest=json.loads((release/"asset-manifest.json").read_text())
rows=[]
for row in manifest["files"]:
    p=release/row["path"]
    if not p.is_file(): raise SystemExit(f"[COSYVOICE3-HF-FINISH] downloaded file missing: {row['path']}")
    h=hashlib.sha256()
    with p.open("rb") as f:
        for c in iter(lambda:f.read(8*1024*1024),b""): h.update(c)
    if p.stat().st_size!=int(row["bytes"]) or h.hexdigest()!=row["sha256"]:
        raise SystemExit(f"[COSYVOICE3-HF-FINISH] downloaded file mismatch: {row['path']}")
    rows.append(row)
tree=hashlib.sha256()
for row in sorted(rows,key=lambda x:x["path"]):
    tree.update(row["path"].encode());tree.update(b"\0");tree.update(str(int(row["bytes"])).encode());tree.update(b"\0");tree.update(row["sha256"].encode());tree.update(b"\n")
if tree.hexdigest()!=receipt["payloadTreeSha256"] or tree.hexdigest()!=manifest["payloadTreeSha256"]:
    raise SystemExit("[COSYVOICE3-HF-FINISH] immutable downloaded payload tree mismatch")
print(f"[COSYVOICE3-HF-FINISH] IMMUTABLE_DOWNLOAD_PASS revision={revision} tree={tree.hexdigest()}",flush=True)
PY
    "$PYTHON" "$ROOT/assets/validate_assets.py" --root "$DOWNLOADED_RELEASE" --require-reference || return $?
}

register_catalog_entry() {
    printf '\n[COSYVOICE3-HF-FINISH] STEP 5/8 build candidate release catalog for exact HF commit\n'
    mkdir -p "$(dirname "$WORK_CATALOG")"
    cp "$ROOT/assets/releases.json" "$WORK_CATALOG" || return $?
    "$PYTHON" - "$WORK_CATALOG" "$UPLOAD_RECEIPT" "$DOWNLOADED_RELEASE/asset-manifest.json" <<'PY'
import json,sys
from pathlib import Path
catalog_path=Path(sys.argv[1]);upload=json.loads(Path(sys.argv[2]).read_text());manifest=json.loads(Path(sys.argv[3]).read_text())
catalog=json.loads(catalog_path.read_text())
if catalog.get("schemaVersion")!=1 or catalog.get("engine")!="CosyVoice3" or catalog.get("platform")!="iOS":
    raise SystemExit("[COSYVOICE3-HF-FINISH] release catalog schema mismatch")
entry={
    "profile":manifest["profile"],
    "version":manifest["assetVersion"],
    "distributionStatus":"PRIVATE_RC",
    "repoId":upload["repoId"],
    "repoType":"model",
    "revision":upload["commit"],
    "tag":upload["tag"],
    "pathInRepo":upload["pathInRepo"],
    "payloadTreeSha256":manifest["payloadTreeSha256"],
    "testedRuntimeTreeSha256":manifest["testedRuntimeTreeSha256"],
    "minimumIOS":manifest["minimumIOS"],
    "runtimeProfile":manifest["runtimeProfile"],
    "referenceStatus":manifest["referenceStatus"],
    "licenseGate":manifest["licenseGate"],
    "requiresAuthentication":True,
    "technicalDistributionStatus":"READY",
    "publicReleaseStatus":"PENDING",
    "publicRedistributionApproved":False,
}
rows=list(catalog.get("releases") or [])
same=[row for row in rows if row.get("profile")==entry["profile"] and row.get("version")==entry["version"]]
if same:
    if len(same)!=1 or same[0]!=entry:
        raise SystemExit("[COSYVOICE3-HF-FINISH] conflicting catalog entry already exists")
else:
    rows.append(entry)
catalog["default"]={"profile":entry["profile"],"version":entry["version"]}
catalog["releases"]=rows
catalog_path.write_text(json.dumps(catalog,indent=2)+"\n")
print("[COSYVOICE3-HF-FINISH] CATALOG_PASS "+json.dumps(entry,sort_keys=True),flush=True)
PY
}

ordinary_fetch() {
    printf '\n[COSYVOICE3-HF-FINISH] STEP 6/8 ordinary-developer immutable fetch\n'
    rm -rf "$FETCHED_RUNTIME"
    "$PYTHON" "$ROOT/assets/fetch_assets.py"         --catalog "$WORK_CATALOG"         --profile "$PROFILE"         --version "$VERSION"         --output "$FETCHED_RUNTIME"         --force || return $?
}

physical_hf_replay() {
    printf '\n[COSYVOICE3-HF-FINISH] STEP 7/8 physical public-API replay from fetched HF runtime\n'
    [ -f "$REFERENCE_WAV" ] || { fail "reference WAV missing: $REFERENCE_WAV"; return 1; }
    [ -f "$REFERENCE_TRANSCRIPT" ] || { fail "reference transcript missing: $REFERENCE_TRANSCRIPT"; return 1; }

    COSYVOICE3_PROMOTED_RUNTIME_MODE=1     COSYVOICE3_FRESH_INSTALL=1     COSYVOICE3_ASSET_ROOT="$FETCHED_RUNTIME"     COSYVOICE3_HOST_PARITY_RECEIPT="$HOST_RECEIPT"     COSYVOICE3_REFERENCE_WAV="$REFERENCE_WAV"     COSYVOICE3_REFERENCE_TRANSCRIPT="$REFERENCE_TRANSCRIPT"     DEVICE_ID="$DEVICE_ID"     DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"     BUNDLE_ID="$REPLAY_BUNDLE_ID"     bash "$ROOT/validation/install_device_smoke.sh" || return $?

    rm -f "$REPLAY_RECEIPT"
    local attempt
    for attempt in $(seq 1 24); do
        printf '[COSYVOICE3-HF-FINISH] replay receipt poll %s/24\n' "$attempt"
        rm -f "$REPLAY_RECEIPT"
        if xcrun devicectl device copy from             --device "$DEVICE_ID"             --domain-type appDataContainer             --domain-identifier "$REPLAY_BUNDLE_ID"             --source "Documents/reference-smoke-receipt.json"             --destination "$REPLAY_RECEIPT"
        then
            if [ -s "$REPLAY_RECEIPT" ]; then
                break
            fi
        fi
        sleep 10
    done
    [ -s "$REPLAY_RECEIPT" ] || {
        fail "HF replay receipt was not produced within 240 seconds"
        return 1
    }

    "$PYTHON" - "$REPLAY_RECEIPT" "$HOST_RECEIPT" "$FETCHED_RUNTIME/asset-manifest.json" "$UPLOAD_RECEIPT" "$FINAL_RECEIPT" <<'PY'
import hashlib,json,sys,time
from pathlib import Path
device=json.loads(Path(sys.argv[1]).read_text());host_path=Path(sys.argv[2]);manifest=json.loads(Path(sys.argv[3]).read_text());upload=json.loads(Path(sys.argv[4]).read_text())
h=hashlib.sha256(host_path.read_bytes()).hexdigest()
if device.get("status")!="PASS_DEVICE_PUBLIC_API_REFERENCE_PCM":
    raise SystemExit(f"[COSYVOICE3-HF-FINISH] HF replay device receipt is not PASS: {device}")
if device.get("sampleRate")!=24000 or device.get("channels")!=1 or int(device.get("samples",0))<=0 or device.get("finite") is not True:
    raise SystemExit("[COSYVOICE3-HF-FINISH] HF replay PCM contract failed")
if device.get("hostReceiptSha256")!=h:
    raise SystemExit("[COSYVOICE3-HF-FINISH] HF replay host receipt binding failed")
receipt={
    "schemaVersion":1,
    "status":"PASS",
    "profile":manifest["profile"],
    "version":manifest["assetVersion"],
    "repoId":upload["repoId"],
    "revision":upload["commit"],
    "tag":upload["tag"],
    "visibility":upload["visibility"],
    "payloadTreeSha256":manifest["payloadTreeSha256"],
    "testedRuntimeTreeSha256":manifest["testedRuntimeTreeSha256"],
    "ordinaryDeveloperFetchPass":True,
    "publicApiDeviceReplayPass":True,
    "deviceStatus":device["status"],
    "sampleRate":device["sampleRate"],
    "channels":device["channels"],
    "samples":device["samples"],
    "durationSeconds":device.get("durationSeconds"),
    "elapsedSeconds":device.get("elapsedSeconds"),
    "rtf":device.get("rtf"),
    "recordedAtUnix":int(time.time()),
}
Path(sys.argv[5]).parent.mkdir(parents=True,exist_ok=True)
Path(sys.argv[5]).write_text(json.dumps(receipt,indent=2,sort_keys=True)+"\n")
print("[COSYVOICE3-HF-FINISH] HF_REPLAY_PASS "+json.dumps(receipt,sort_keys=True),flush=True)
PY
}

record_release_milestone_and_push() {
    printf '\n[COSYVOICE3-HF-FINISH] STEP 8/8 atomically accept catalog, record private-RC milestone and push\n'
    [ -s "$WORK_CATALOG" ] || { fail "candidate release catalog missing: $WORK_CATALOG"; return 1; }
    cp "$WORK_CATALOG" "$ROOT/assets/releases.json" || return $?
    "$PYTHON" - "$ROOT/manifest.json" "$ROOT/VALIDATION.md" "$UPLOAD_RECEIPT" "$DOWNLOADED_RELEASE/asset-manifest.json" <<'PY'
import json,sys
from pathlib import Path
manifest_path=Path(sys.argv[1]);checklist_path=Path(sys.argv[2]);upload=json.loads(Path(sys.argv[3]).read_text());asset=json.loads(Path(sys.argv[4]).read_text())
m=json.loads(manifest_path.read_text())
m["assetDistribution"]={
    "status":"PRIVATE_RC_IMMUTABLE_REPLAY_PASS",
    "profile":asset["profile"],
    "version":asset["assetVersion"],
    "repoId":upload["repoId"],
    "revision":upload["commit"],
    "tag":upload["tag"],
    "pathInRepo":upload["pathInRepo"],
    "payloadTreeSha256":asset["payloadTreeSha256"],
    "requiresAuthentication":True,
    "publicRedistributionApproved":False,
}
m["candidateBlockers"]=[x for x in m.get("candidateBlockers",[]) if x!="immutable asset fetch"]
manifest_path.write_text(json.dumps(m,indent=2)+"\n")
text=checklist_path.read_text()
needle="PASS: custom-reference lane is promoted to `PASS_DEVICE_PARITY`.\n"
addition=(
    needle+
    "PASS: complete fixed225-reference runtime is uploaded as an immutable private Hugging Face RC and the exact commit passes ordinary-developer fetch plus physical public-API replay.\n"
)
if "immutable private Hugging Face RC" not in text:
    if needle not in text: raise SystemExit("[COSYVOICE3-HF-FINISH] checklist insertion point missing")
    text=text.replace(needle,addition,1)
text=text.replace("BLOCKER: immutable hosted asset manifest/fetch path is incomplete.\n","")
checklist_path.write_text(text)
PY

    local repo_root status
    repo_root="$(git -C "$ROOT/.." rev-parse --show-toplevel)" || return $?
    status="$(git -C "$repo_root" status --porcelain --untracked-files=no)" || return $?
    printf '[COSYVOICE3-HF-FINISH] tracked changes before release commit:\n%s\n' "$status"

    local unexpected
    unexpected="$(git -C "$repo_root" diff --name-only -- .         ':(exclude)ios/assets/releases.json'         ':(exclude)ios/manifest.json'         ':(exclude)ios/VALIDATION.md')"
    if [ -n "$unexpected" ]; then
        printf '%s\n' "$unexpected"
        fail "tracked changes exist outside the accepted HF release metadata"
        return 1
    fi

    git -C "$repo_root" add         ios/assets/releases.json         ios/manifest.json         ios/VALIDATION.md || return $?
    git -C "$repo_root" -c user.name="actacomes" -c user.email="developer@actacomes.com"         commit -m "release(ios): register fixed225 reference private RC" || return $?
    git -C "$repo_root" push origin "$EXPECTED_BRANCH" || return $?
    printf '[COSYVOICE3-HF-FINISH] RELEASE_METADATA_PUSH_PASS head=%s\n' "$(git -C "$repo_root" rev-parse HEAD)"
}

main() {
    command -v git || return $?
    command -v python3 || return $?
    command -v xcrun || return $?
    command -v xcodebuild || return $?
    cd "$ROOT" || return $?

    printf '[COSYVOICE3-HF-FINISH] profile=%s version=%s repo=%s\n' "$PROFILE" "$VERSION" "$REPO_ID"
    ensure_clean_checkout || return $?
    git -C "$ROOT/.." pull --ff-only origin "$EXPECTED_BRANCH" || return $?
    ensure_release_python_and_hf_identity || return $?
    validate_canonical_runtime || return $?
    prepare_release || return $?
    upload_private_rc || return $?
    download_and_verify_immutable_commit || return $?
    register_catalog_entry || return $?
    ordinary_fetch || return $?
    physical_hf_replay || return $?
    record_release_milestone_and_push || return $?

    printf '\n[COSYVOICE3-HF-FINISH] COMPLETE privateRC=PASS immutableFetch=PASS physicalReplay=PASS repo=%s version=%s finalReceipt=%s\n'         "$REPO_ID" "$VERSION" "$FINAL_RECEIPT"
}

main "$@"
RC=$?
printf '[COSYVOICE3-HF-FINISH] rc=%s\n' "$RC"
test "$RC" -eq 0

# Code purpose: one-command private Hugging Face RC publication, immutable commit replay, ordinary-developer fetch, physical public-API replay, and accepted release-catalog push for CosyVoice3 iOS fixed225-reference; tracked releases.json is not mutated until all replay gates pass.
# Upstream evidence: promoted canonical runtime, PASS_HOST_PARITY, PASS_DEVICE_PUBLIC_API_REFERENCE_PCM, and PASS_CUSTOM_REFERENCE_DEVICE_PROMOTION.
# Runtime: macOS/Xcode, connected physical iPhone, authenticated Hugging Face account actacomes, and Git push access.
# Generated: 2026-10-02 America/New_York.

# Changes 2026-10-03: use VALIDATION.md as the engine-owned release-status document; RELEASE_CHECKLIST.md was retired from the release branch.

# Changes 2026-10-03: private-RC workflow targets the explicit SDK release branch instead of main; override only with COSYVOICE3_RELEASE_BRANCH for an intentional alternate release branch.
