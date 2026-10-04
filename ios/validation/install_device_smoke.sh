#@title install_device_smoke.sh
# Requirement: stage a host-parity-approved fixed225 or dynamic custom-reference candidate, build/sign/install/launch the clean public-API smoke app on a selected or auto-detected physical iPhone.
#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/validation/DeviceSmoke/CosyVoice3DeviceSmoke.xcodeproj"
SCHEME="CosyVoice3DeviceSmoke"
CONFIGURATION="${CONFIGURATION:-Debug}"
BUNDLE_ID="${BUNDLE_ID:-com.actacomes.cosyvoice3.devicesmoke}"
DERIVED_DATA="${DERIVED_DATA:-$ROOT/.work/DeviceSmokeDerivedData}"
SOURCE_ROOT="${COSYVOICE3_SOURCE_ROOT:-/Volumes/WD/Codes/CosyVoice3_NPU}"
ASSET_ROOT="${COSYVOICE3_ASSET_ROOT:-$ROOT/.work/device-runtime}"
HOST_RECEIPT="${COSYVOICE3_HOST_PARITY_RECEIPT:-$ROOT/.work/reference-release/parity/reference_host_parity_receipt.json}"
REFERENCE_CANDIDATE_DIR="${COSYVOICE3_REFERENCE_CANDIDATE_DIR:-$ROOT/.work/reference-release/coreml}"
PYTHON_BIN="${COSYVOICE3_PYTHON:-$HOME/.venvs/cosyvoice-reference-py311/bin/python3}"
PROMOTED_RUNTIME_MODE="${COSYVOICE3_PROMOTED_RUNTIME_MODE:-0}"
FRESH_INSTALL="${COSYVOICE3_FRESH_INSTALL:-0}"
CANDIDATE_BENCHMARK="${COSYVOICE3_CANDIDATE_BENCHMARK:-0}"
FLOW_STEPS_HEAD_TO_HEAD="${COSYVOICE3_FLOW_STEPS_HEAD_TO_HEAD:-0}"
DYNAMIC_PUBLIC_API_SMOKE="${COSYVOICE3_DYNAMIC_PUBLIC_API_SMOKE:-0}"

main() {
    MODE_COUNT=0
    [ "$CANDIDATE_BENCHMARK" = "1" ] && MODE_COUNT=$((MODE_COUNT+1))
    [ "$FLOW_STEPS_HEAD_TO_HEAD" = "1" ] && MODE_COUNT=$((MODE_COUNT+1))
    [ "$DYNAMIC_PUBLIC_API_SMOKE" = "1" ] && MODE_COUNT=$((MODE_COUNT+1))
    if [ "$MODE_COUNT" -gt 1 ]; then printf '[COSYVOICE3-INSTALL] ERROR Candidate benchmark, Flow head-to-head and dynamic public-API smoke modes are mutually exclusive\n'; return 2; fi
    if [ -z "${DEVELOPMENT_TEAM:-}" ]; then printf '[COSYVOICE3-INSTALL] ERROR set DEVELOPMENT_TEAM\n'; return 2; fi
    REUSE_INPUT_DIR="$ROOT/.work/device-smoke-reused-input"
    if [ -z "${COSYVOICE3_REFERENCE_WAV:-}" ]; then
        if [ -f "$ROOT/validation/DeviceSmoke/GeneratedAssets/reference.wav" ]; then
            mkdir -p "$REUSE_INPUT_DIR"
            cp "$ROOT/validation/DeviceSmoke/GeneratedAssets/reference.wav" "$REUSE_INPUT_DIR/reference.wav"
            COSYVOICE3_REFERENCE_WAV="$REUSE_INPUT_DIR/reference.wav"
            printf '[COSYVOICE3-INSTALL] reusing previously staged reference WAV via %s\n' "$COSYVOICE3_REFERENCE_WAV"
        else
            printf '[COSYVOICE3-INSTALL] ERROR set COSYVOICE3_REFERENCE_WAV\n'; return 2
        fi
    fi
    if [ -z "${COSYVOICE3_REFERENCE_TRANSCRIPT:-}" ]; then
        if [ -f "$ROOT/validation/DeviceSmoke/GeneratedAssets/reference.txt" ]; then
            mkdir -p "$REUSE_INPUT_DIR"
            cp "$ROOT/validation/DeviceSmoke/GeneratedAssets/reference.txt" "$REUSE_INPUT_DIR/reference.txt"
            COSYVOICE3_REFERENCE_TRANSCRIPT="$REUSE_INPUT_DIR/reference.txt"
            printf '[COSYVOICE3-INSTALL] reusing previously staged reference transcript via %s\n' "$COSYVOICE3_REFERENCE_TRANSCRIPT"
        else
            printf '[COSYVOICE3-INSTALL] ERROR set COSYVOICE3_REFERENCE_TRANSCRIPT\n'; return 2
        fi
    fi
    if [ ! -f "$HOST_RECEIPT" ] && [ -f "$ROOT/validation/DeviceSmoke/GeneratedAssets/reference_host_parity_receipt.json" ]; then
        mkdir -p "$REUSE_INPUT_DIR"
        cp "$ROOT/validation/DeviceSmoke/GeneratedAssets/reference_host_parity_receipt.json" "$REUSE_INPUT_DIR/reference_host_parity_receipt.json"
        HOST_RECEIPT="$REUSE_INPUT_DIR/reference_host_parity_receipt.json"
        printf '[COSYVOICE3-INSTALL] reusing previously staged host parity receipt via %s\n' "$HOST_RECEIPT"
    fi

    if [ ! -x "$PYTHON_BIN" ]; then printf '[COSYVOICE3-INSTALL] ERROR Python environment missing: %s\n' "$PYTHON_BIN"; return 2; fi
    command -v xcodebuild || return $?
    command -v xcrun || return $?
    command -v swift || return $?
    cd "$ROOT" || return $?

    if [ -z "${DEVICE_ID:-}" ]; then
        DESTINATIONS="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -showdestinations 2>&1)"
        printf '%s\n' "$DESTINATIONS"
        DEVICE_ID="$(printf '%s\n' "$DESTINATIONS" | sed -n 's/.*{ platform:iOS, arch:arm64, id:\([^,}]*\), name:.*/\1/p' | head -n 1 | xargs)"
        if [ -z "$DEVICE_ID" ]; then printf '[COSYVOICE3-INSTALL] ERROR no available physical iPhone destination\n'; return 2; fi
        printf '[COSYVOICE3-INSTALL] auto-selected physical iPhone device=%s\n' "$DEVICE_ID"
    fi

    printf '[COSYVOICE3-INSTALL] root=%s\n' "$ROOT"
    printf '[COSYVOICE3-INSTALL] team=%s device=%s bundle=%s configuration=%s\n' "$DEVELOPMENT_TEAM" "$DEVICE_ID" "$BUNDLE_ID" "$CONFIGURATION"
    printf '[COSYVOICE3-INSTALL] sourceRoot=%s assetRoot=%s\n' "$SOURCE_ROOT" "$ASSET_ROOT"
    printf '[COSYVOICE3-INSTALL] hostReceipt=%s referenceCandidates=%s\n' "$HOST_RECEIPT" "$REFERENCE_CANDIDATE_DIR"
    xcrun devicectl list devices || return $?

    if [ "$PROMOTED_RUNTIME_MODE" = "1" ]; then
        printf '[COSYVOICE3-INSTALL] promoted-runtime mode: exact runtime must already contain PASS_DEVICE_PARITY reference assets\n'
        "$PYTHON_BIN" assets/validate_assets.py --root "$ASSET_ROOT" --require-reference || return $?
    else
        if [ ! -f "$ASSET_ROOT/cosyvoice3_fixed225.json" ] || [ ! -f "$ASSET_ROOT/tokenizer/tokenizer.json" ]; then
            printf '[COSYVOICE3-INSTALL] assembling standalone fixed225 runtime from validated migration assets\n'
            ASSEMBLE_FORCE_ARGS=()
            case "$ASSET_ROOT" in
                "$ROOT/.work/"*)
                    if [ -e "$ASSET_ROOT" ]; then
                        printf '[COSYVOICE3-INSTALL] replacing incomplete tool-owned runtime: %s\n' "$ASSET_ROOT"
                        ASSEMBLE_FORCE_ARGS=(--force)
                    fi
                    ;;
                *)
                    if [ -e "$ASSET_ROOT" ]; then
                        printf '[COSYVOICE3-INSTALL] ERROR custom asset root exists without manifest; refusing to overwrite: %s\n' "$ASSET_ROOT"
                        return 2
                    fi
                    ;;
            esac
            "$PYTHON_BIN" validation/assemble_fixed225_runtime_from_migration.py \
                --source-root "$SOURCE_ROOT" \
                --output "$ASSET_ROOT" \
                "${ASSEMBLE_FORCE_ARGS[@]}" || return $?
        fi
    fi

    printf '[COSYVOICE3-INSTALL] validating exact native tokenizer parity before iPhone build\n'
    COSYVOICE3_TOKENIZER_PARITY_FOLDER="$ASSET_ROOT/tokenizer" \
        swift test --package-path "$ROOT" --filter ReferenceTokenizerExternalParityTests || return $?

    STAGING_ARGS=()
    if [ "$CANDIDATE_BENCHMARK" = "1" ]; then STAGING_ARGS+=(--candidate-benchmark); fi
    if [ "$FLOW_STEPS_HEAD_TO_HEAD" = "1" ]; then STAGING_ARGS+=(--flow-steps-head-to-head); fi
    if [ "$DYNAMIC_PUBLIC_API_SMOKE" = "1" ]; then STAGING_ARGS+=(--dynamic-public-api-smoke); fi

    EXACT_RUNTIME_MODE="$PROMOTED_RUNTIME_MODE"
    if [ "$DYNAMIC_PUBLIC_API_SMOKE" = "1" ] && [ "$EXACT_RUNTIME_MODE" != "1" ]; then
        ACTIVE_REFERENCE_STATUS="$("$PYTHON_BIN" - "$ASSET_ROOT" <<'PY'
import json,pathlib,sys
root=pathlib.Path(sys.argv[1])
p=root/"cosyvoice3_dynamic.json"
if not p.exists(): p=root/"cosyvoice3_fixed225.json"
try:
    m=json.loads(p.read_text()); print((m.get("referenceEnrollment") or {}).get("status",""))
except Exception:
    print("")
PY
)"
        if [ "$ACTIVE_REFERENCE_STATUS" = "PASS_DEVICE_PARITY" ]; then
            EXACT_RUNTIME_MODE=1
            printf '[COSYVOICE3-INSTALL] dynamic candidate already carries PASS_DEVICE_PARITY reference assets; exact-staging runtime bytes\n'
        fi
    fi

    if [ "$EXACT_RUNTIME_MODE" = "1" ]; then
        "$PYTHON_BIN" validation/prepare_promoted_device_smoke_assets.py \
            --asset-root "$ASSET_ROOT" \
            --host-receipt "$HOST_RECEIPT" \
            --reference-wav "$COSYVOICE3_REFERENCE_WAV" \
            --reference-transcript "$COSYVOICE3_REFERENCE_TRANSCRIPT" \
            "${STAGING_ARGS[@]}" || return $?
    else
        "$PYTHON_BIN" validation/prepare_device_smoke_assets.py \
            --asset-root "$ASSET_ROOT" \
            --host-receipt "$HOST_RECEIPT" \
            --reference-candidate-dir "$REFERENCE_CANDIDATE_DIR" \
            --reference-wav "$COSYVOICE3_REFERENCE_WAV" \
            --reference-transcript "$COSYVOICE3_REFERENCE_TRANSCRIPT" \
            "${STAGING_ARGS[@]}" || return $?
    fi

    rm -rf "$DERIVED_DATA"
    XCODE_ARGS=(
        -project "$PROJECT"
        -scheme "$SCHEME"
        -configuration "$CONFIGURATION"
        -sdk iphoneos
        -destination "id=$DEVICE_ID"
        -derivedDataPath "$DERIVED_DATA"
        -allowProvisioningUpdates
        -allowProvisioningDeviceRegistration
        DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"
        PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID"
        CODE_SIGN_STYLE=Automatic
    )
    xcodebuild "${XCODE_ARGS[@]}" build || return $?

    printf '[COSYVOICE3-INSTALL] resolving actual Xcode product path from build settings\n'
    BUILD_SETTINGS="$(xcodebuild "${XCODE_ARGS[@]}" -showBuildSettings)" || return $?
    TARGET_BUILD_DIR="$(
        printf '%s\n' "$BUILD_SETTINGS" |
        awk '
            /Build settings for action build and target CosyVoice3DeviceSmoke:/ { in_target=1; next }
            in_target && /^[[:space:]]*TARGET_BUILD_DIR = / {
                sub(/^[[:space:]]*TARGET_BUILD_DIR = /, "")
                print
                exit
            }
        '
    )"
    WRAPPER_NAME="$(
        printf '%s\n' "$BUILD_SETTINGS" |
        awk '
            /Build settings for action build and target CosyVoice3DeviceSmoke:/ { in_target=1; next }
            in_target && /^[[:space:]]*WRAPPER_NAME = / {
                sub(/^[[:space:]]*WRAPPER_NAME = /, "")
                print
                exit
            }
        '
    )"
    if [ -z "$TARGET_BUILD_DIR" ] || [ -z "$WRAPPER_NAME" ]; then
        printf '[COSYVOICE3-INSTALL] ERROR could not resolve TARGET_BUILD_DIR/WRAPPER_NAME from Xcode build settings\n'
        return 3
    fi
    APP="$TARGET_BUILD_DIR/$WRAPPER_NAME"
    printf '[COSYVOICE3-INSTALL] targetBuildDir=%s wrapper=%s\n' "$TARGET_BUILD_DIR" "$WRAPPER_NAME"
    if [ ! -d "$APP" ]; then printf '[COSYVOICE3-INSTALL] ERROR app not found at resolved Xcode product path: %s\n' "$APP"; return 3; fi
    if [ "$FRESH_INSTALL" = "1" ]; then
        printf '[COSYVOICE3-INSTALL] requesting fresh install by removing prior bundle %s\n' "$BUNDLE_ID"
        if xcrun devicectl device uninstall app --device "$DEVICE_ID" "$BUNDLE_ID"; then
            printf '[COSYVOICE3-INSTALL] prior bundle removed\n'
        else
            printf '[COSYVOICE3-INSTALL] prior bundle was absent or could not be removed; continuing to install\n'
        fi
    fi
    xcrun devicectl device install app --device "$DEVICE_ID" "$APP" || return $?
    DYNAMIC_LAUNCH_UNIX="$(date +%s)"
    xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID" || return $?
    printf '[COSYVOICE3-INSTALL] PASS app=%s bundle=%s device=%s\n' "$APP" "$BUNDLE_ID" "$DEVICE_ID"
    if [ "$DYNAMIC_PUBLIC_API_SMOKE" = "1" ]; then
        DYNAMIC_EVIDENCE="$ROOT/validation/evidence/dynamic-public-api-smoke-$DYNAMIC_LAUNCH_UNIX"
        mkdir -p "$DYNAMIC_EVIDENCE"
        DYNAMIC_RECEIPT="$DYNAMIC_EVIDENCE/dynamic-public-api-smoke-receipt.json"
        DYNAMIC_TMP="$DYNAMIC_RECEIPT.tmp"
        DYNAMIC_DEADLINE=$((DYNAMIC_LAUNCH_UNIX+1800))
        printf '[COSYVOICE3-INSTALL] polling dynamic public-API smoke receipt into %s\n' "$DYNAMIC_EVIDENCE"
        DYNAMIC_LAST_PROGRESS=""
        DYNAMIC_LAST_CHANGE_UNIX="$DYNAMIC_LAUNCH_UNIX"
        DYNAMIC_COPY_LOG="$DYNAMIC_EVIDENCE/devicectl-copy.log"
        while true; do
            rm -f "$DYNAMIC_TMP"
            if xcrun devicectl device copy from --device "$DEVICE_ID" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" --source "Documents/dynamic-public-api-smoke-receipt.json" --destination "$DYNAMIC_TMP" >"$DYNAMIC_COPY_LOG" 2>&1; then
                if [ -s "$DYNAMIC_TMP" ]; then
                    DYNAMIC_ROW="$("$PYTHON_BIN" - "$DYNAMIC_TMP" <<'PY'
import json,sys
try:
    r=json.load(open(sys.argv[1]))
    print("|".join(str(r.get(k,"")) for k in ("status","phase","defaultInferredSpeechTokensFromPCM","defaultSamples","updatedAtUnix")))
except Exception:
    print("||||")
PY
)"
                    IFS='|' read -r DYNAMIC_STATUS DYNAMIC_PHASE DYNAMIC_DEFAULT_N DYNAMIC_DEFAULT_SAMPLES DYNAMIC_UPDATED_UNIX <<<"$DYNAMIC_ROW"
                    DYNAMIC_PROGRESS="$DYNAMIC_STATUS|$DYNAMIC_PHASE|$DYNAMIC_DEFAULT_N|$DYNAMIC_DEFAULT_SAMPLES"
                    if [ "$DYNAMIC_PROGRESS" != "$DYNAMIC_LAST_PROGRESS" ]; then
                        printf '[COSYVOICE3-INSTALL] dynamic progress status=%s phase=%s defaultN=%s defaultSamples=%s\n' "$DYNAMIC_STATUS" "$DYNAMIC_PHASE" "${DYNAMIC_DEFAULT_N:-NA}" "${DYNAMIC_DEFAULT_SAMPLES:-NA}"
                        DYNAMIC_LAST_PROGRESS="$DYNAMIC_PROGRESS"
                        DYNAMIC_LAST_CHANGE_UNIX="$(date +%s)"
                    fi
                    if [ "$DYNAMIC_STATUS" = "PASS_DYNAMIC_PUBLIC_API_DEFAULT_AND_REFERENCE" ]; then
                        mv "$DYNAMIC_TMP" "$DYNAMIC_RECEIPT"
                        break
                    fi
                    if [ "$DYNAMIC_STATUS" = "FAIL" ]; then
                        mv "$DYNAMIC_TMP" "$DYNAMIC_RECEIPT"
                        "$PYTHON_BIN" -m json.tool "$DYNAMIC_RECEIPT"
                        printf '[COSYVOICE3-INSTALL] ERROR dynamic public-API smoke failed\n'
                        return 4
                    fi
                fi
            fi
            DYNAMIC_NOW="$(date +%s)"
            if [ $((DYNAMIC_NOW-DYNAMIC_LAST_CHANGE_UNIX)) -ge 600 ]; then
                if [ -s "$DYNAMIC_TMP" ]; then cp "$DYNAMIC_TMP" "$DYNAMIC_RECEIPT"; fi
                printf '[COSYVOICE3-INSTALL] ERROR dynamic public-API smoke made no phase progress for 600 seconds; latest receipt follows\n'
                if [ -s "$DYNAMIC_RECEIPT" ]; then "$PYTHON_BIN" -m json.tool "$DYNAMIC_RECEIPT"; fi
                printf '[COSYVOICE3-INSTALL] devicectl copy log=%s\n' "$DYNAMIC_COPY_LOG"
                return 6
            fi
            if [ "$DYNAMIC_NOW" -ge "$DYNAMIC_DEADLINE" ]; then
                printf '[COSYVOICE3-INSTALL] ERROR dynamic public-API smoke receipt timeout\n'
                return 5
            fi
            sleep 5
        done
        for WAV_NAME in dynamic-default.wav dynamic-reference.wav; do
            xcrun devicectl device copy from --device "$DEVICE_ID" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" --source "Documents/$WAV_NAME" --destination "$DYNAMIC_EVIDENCE/$WAV_NAME" || return $?
        done
        EXPECTED_SOURCE_COMMIT="$(git -C "$ROOT/.." rev-parse HEAD)"
        "$PYTHON_BIN" - "$DYNAMIC_RECEIPT" "$EXPECTED_SOURCE_COMMIT" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]));expected=sys.argv[2]
assert r["status"]=="PASS_DYNAMIC_PUBLIC_API_DEFAULT_AND_REFERENCE",r.get("status")
assert r.get("sourceCommit")==expected,(r.get("sourceCommit"),expected)
assert str(r.get("profile","")).startswith("ios18-dynamic-"),r.get("profile")
lo,hi=map(int,r["speechTokenBounds"])
for lane in ("default","reference"):
    n=int(r[lane]["inferredSpeechTokensFromPCM"])
    assert lo<=n<=hi,(lane,n,lo,hi)
    assert int(r[lane]["samples"])==960*n,(lane,r[lane]["samples"],n)
assert r.get("flowSteps")==6,r.get("flowSteps")
assert r.get("productionPromotion") is False,r.get("productionPromotion")
print("DYNAMIC_PUBLIC_API_STATUS",r["status"])
print("PROFILE",r["profile"])
print("N_BOUNDS",r["speechTokenBounds"])
print("DEFAULT_N",r["default"]["inferredSpeechTokensFromPCM"],"SAMPLES",r["default"]["samples"])
print("REFERENCE_N",r["reference"]["inferredSpeechTokensFromPCM"],"SAMPLES",r["reference"]["samples"])
print("SOURCE_COMMIT",r["sourceCommit"])
PY
        printf '[COSYVOICE3-INSTALL] PASS dynamic evidence=%s\n' "$DYNAMIC_EVIDENCE"
        printf '[COSYVOICE3-INSTALL] WAV default=%s reference=%s\n' "$DYNAMIC_EVIDENCE/dynamic-default.wav" "$DYNAMIC_EVIDENCE/dynamic-reference.wav"
    elif [ "$FLOW_STEPS_HEAD_TO_HEAD" = "1" ]; then
        printf '[COSYVOICE3-INSTALL] App auto-runs Flow 10/8/6 head-to-head. Retrieve Documents/flow-steps-head-to-head-receipt.json and flow-steps-{10,8,6}.wav.\n'
    elif [ "$CANDIDATE_BENCHMARK" = "1" ]; then
        printf '[COSYVOICE3-INSTALL] App auto-runs Candidate benchmark. Retrieve Documents/candidate-benchmark-receipt.json.\n'
    else
        printf '[COSYVOICE3-INSTALL] App auto-runs once. Copy Documents/reference-smoke-receipt.json after PASS and feed it to tools/promote_reference_assets.py.\n'
    fi
}

main "$@"
RC=$?
printf '[COSYVOICE3-INSTALL] rc=%s\n' "$RC"
test "$RC" -eq 0

# Code purpose: one-command physical-iPhone build/install/launch for standalone public CosyVoice3Core custom-reference smoke; supports ordinary local-candidate staging and exact already-promoted runtime replay without substituting local reference models.
# Runtime: macOS, Xcode, Python3, connected/trusted iPhone.
# Generated: 2026-10-02 America/New_York.\n# Changes 2026-10-02: COSYVOICE3_CANDIDATE_BENCHMARK=1 stages the benchmark marker and makes DeviceSmoke auto-run the cold/warm public-API benchmark without changing the normal smoke path.

# Changes 2026-10-02: COSYVOICE3_FLOW_STEPS_HEAD_TO_HEAD=1 stages and auto-runs the validation-only 10/8/6 Flow comparison; it is mutually exclusive with Candidate benchmark mode.

# Changes 2026-10-04: add COSYVOICE3_DYNAMIC_PUBLIC_API_SMOKE=1 and auto-detect the first available physical iPhone when DEVICE_ID is unset; existing explicit DEVICE_ID remains authoritative.

# Changes 2026-10-04: dynamic smoke exact-stages candidate runtime bytes automatically when the active manifest already carries PASS_DEVICE_PARITY reference enrollment; otherwise it falls back to host-approved local reference staging.

# Changes 2026-10-04: if explicit reference WAV/transcript or default host receipt is unavailable, safely copy prior DeviceSmoke staged inputs into ios/.work before staging replaces GeneratedAssets; explicit environment values remain authoritative.

# Changes 2026-10-04: dynamic smoke now polls the physical app receipt in foreground, retrieves both WAVs, and fail-closed verifies PASS status, exact Git HEAD binding, dynamic profile, N bounds, PCM=960*N, Flow6 and non-promotion before returning success.

# Changes 2026-10-04: host poller now reports durable RUNNING phase transitions and the completed default-lane N/samples when available; final PASS/FAIL semantics are unchanged.

# Changes 2026-10-04: suppress repetitive successful devicectl copy chatter into a retained log file, print only progress transitions, and fail closed after 600 seconds without a phase change while preserving the latest receipt for diagnosis.
