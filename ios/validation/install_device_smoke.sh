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

main() {
    if [ -z "${DEVELOPMENT_TEAM:-}" ]; then printf '[COSYVOICE3-INSTALL] ERROR set DEVELOPMENT_TEAM\n'; return 2; fi
    if [ -z "${DEVICE_ID:-}" ]; then printf '[COSYVOICE3-INSTALL] ERROR set DEVICE_ID\n'; return 2; fi
    if [ -z "${COSYVOICE3_ASSET_ROOT:-}" ]; then printf '[COSYVOICE3-INSTALL] ERROR set COSYVOICE3_ASSET_ROOT\n'; return 2; fi
    if [ -z "${COSYVOICE3_HOST_PARITY_RECEIPT:-}" ]; then printf '[COSYVOICE3-INSTALL] ERROR set COSYVOICE3_HOST_PARITY_RECEIPT\n'; return 2; fi
    if [ -z "${COSYVOICE3_REFERENCE_CANDIDATE_DIR:-}" ]; then printf '[COSYVOICE3-INSTALL] ERROR set COSYVOICE3_REFERENCE_CANDIDATE_DIR\n'; return 2; fi
    if [ -z "${COSYVOICE3_REFERENCE_WAV:-}" ]; then printf '[COSYVOICE3-INSTALL] ERROR set COSYVOICE3_REFERENCE_WAV\n'; return 2; fi
    if [ -z "${COSYVOICE3_REFERENCE_TRANSCRIPT:-}" ]; then printf '[COSYVOICE3-INSTALL] ERROR set COSYVOICE3_REFERENCE_TRANSCRIPT\n'; return 2; fi

    command -v python3 || return $?
    command -v xcodebuild || return $?
    command -v xcrun || return $?
    cd "$ROOT" || return $?

    printf '[COSYVOICE3-INSTALL] root=%s\n' "$ROOT"
    printf '[COSYVOICE3-INSTALL] team=%s device=%s bundle=%s configuration=%s\n' "$DEVELOPMENT_TEAM" "$DEVICE_ID" "$BUNDLE_ID" "$CONFIGURATION"
    xcrun devicectl list devices || return $?

    python3 validation/prepare_device_smoke_assets.py \
        --asset-root "$COSYVOICE3_ASSET_ROOT" \
        --host-receipt "$COSYVOICE3_HOST_PARITY_RECEIPT" \
        --reference-candidate-dir "$COSYVOICE3_REFERENCE_CANDIDATE_DIR" \
        --reference-wav "$COSYVOICE3_REFERENCE_WAV" \
        --reference-transcript "$COSYVOICE3_REFERENCE_TRANSCRIPT" || return $?

    rm -rf "$DERIVED_DATA"
    xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -sdk iphoneos \
        -destination "id=$DEVICE_ID" \
        -derivedDataPath "$DERIVED_DATA" \
        -allowProvisioningUpdates \
        -allowProvisioningDeviceRegistration \
        DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
        PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
        CODE_SIGN_STYLE=Automatic \
        build || return $?

    APP="$DERIVED_DATA/Build/Products/${CONFIGURATION}-iphoneos/CosyVoice3DeviceSmoke.app"
    if [ ! -d "$APP" ]; then printf '[COSYVOICE3-INSTALL] ERROR app not found: %s\n' "$APP"; return 3; fi
    xcrun devicectl device install app --device "$DEVICE_ID" "$APP" || return $?
    xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID" || return $?
    printf '[COSYVOICE3-INSTALL] PASS app=%s bundle=%s device=%s\n' "$APP" "$BUNDLE_ID" "$DEVICE_ID"
    printf '[COSYVOICE3-INSTALL] App auto-runs once. Copy Documents/reference-smoke-receipt.json after PASS and feed it to tools/promote_reference_assets.py.\n'
}

main "$@"
RC=$?
printf '[COSYVOICE3-INSTALL] rc=%s\n' "$RC"
test "$RC" -eq 0

# Code purpose: one-command physical-iPhone build/install/launch for standalone public CosyVoice3Core custom-reference smoke.
# Runtime: macOS, Xcode, Python3, connected/trusted iPhone.
# Generated: 2026-10-02 America/New_York.
