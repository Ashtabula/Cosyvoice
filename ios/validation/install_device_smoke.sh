#@title install_device_smoke.sh
# Requirement: stage a host-parity-approved fixed225 custom-reference candidate, build/sign/install/launch the clean public-API smoke app on one explicitly selected physical iPhone.
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

main() {
    if [ "$CANDIDATE_BENCHMARK" = "1" ] && [ "$FLOW_STEPS_HEAD_TO_HEAD" = "1" ]; then printf '[COSYVOICE3-INSTALL] ERROR Candidate benchmark and Flow head-to-head modes are mutually exclusive\n'; return 2; fi
    if [ -z "${DEVELOPMENT_TEAM:-}" ]; then printf '[COSYVOICE3-INSTALL] ERROR set DEVELOPMENT_TEAM\n'; return 2; fi
    if [ -z "${DEVICE_ID:-}" ]; then printf '[COSYVOICE3-INSTALL] ERROR set DEVICE_ID\n'; return 2; fi
    if [ -z "${COSYVOICE3_REFERENCE_WAV:-}" ]; then printf '[COSYVOICE3-INSTALL] ERROR set COSYVOICE3_REFERENCE_WAV\n'; return 2; fi
    if [ -z "${COSYVOICE3_REFERENCE_TRANSCRIPT:-}" ]; then printf '[COSYVOICE3-INSTALL] ERROR set COSYVOICE3_REFERENCE_TRANSCRIPT\n'; return 2; fi

    if [ ! -x "$PYTHON_BIN" ]; then printf '[COSYVOICE3-INSTALL] ERROR Python environment missing: %s\n' "$PYTHON_BIN"; return 2; fi
    command -v xcodebuild || return $?
    command -v xcrun || return $?
    command -v swift || return $?
    cd "$ROOT" || return $?

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
    if [ "$PROMOTED_RUNTIME_MODE" = "1" ]; then
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
    xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID" || return $?
    printf '[COSYVOICE3-INSTALL] PASS app=%s bundle=%s device=%s\n' "$APP" "$BUNDLE_ID" "$DEVICE_ID"
    if [ "$FLOW_STEPS_HEAD_TO_HEAD" = "1" ]; then
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
