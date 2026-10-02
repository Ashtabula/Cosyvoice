#@title finalize_reference_device_promotion.sh
# Requirement: pull the latest DeviceSmoke receipt from the connected physical iPhone, validate/promote the custom-reference lane, record evidence, commit as actacomes, and push main.
#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE_ID="${BUNDLE_ID:-com.actacomes.cosyvoice3.devicesmoke}"
ASSET_ROOT="${COSYVOICE3_ASSET_ROOT:-$ROOT/.work/device-runtime}"
HOST_RECEIPT="${COSYVOICE3_HOST_PARITY_RECEIPT:-$ROOT/.work/reference-release/parity/reference_host_parity_receipt.json}"
REFERENCE_CANDIDATE_DIR="${COSYVOICE3_REFERENCE_CANDIDATE_DIR:-$ROOT/.work/reference-release/coreml}"
LISTENING_ACCEPTANCE="$ROOT/validation/reference-device/listening-acceptance.json"
WORK="$ROOT/.work/reference-release/device"
DEVICE_RECEIPT="$WORK/reference-smoke-receipt.json"
PYTHON_BIN="${COSYVOICE3_PYTHON:-$HOME/.venvs/cosyvoice-reference-py311/bin/python3}"
COMMIT_PUSH="${COSYVOICE3_PROMOTION_COMMIT_PUSH:-1}"

main() {
    if [ -z "${DEVICE_ID:-}" ]; then
        printf '[COSYVOICE3-REFERENCE-PROMOTION] ERROR set DEVICE_ID\n'
        return 2
    fi
    if [ ! -x "$PYTHON_BIN" ]; then
        printf '[COSYVOICE3-REFERENCE-PROMOTION] ERROR Python missing: %s\n' "$PYTHON_BIN"
        return 2
    fi
    command -v xcrun || return $?
    command -v git || return $?

    cd "$ROOT/.." || return $?

    if [ "$(git branch --show-current)" != "main" ]; then
        printf '[COSYVOICE3-REFERENCE-PROMOTION] ERROR promotion must run from main\n'
        return 2
    fi

    if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
        printf '[COSYVOICE3-REFERENCE-PROMOTION] ERROR tracked working tree is not clean before promotion\n'
        git status --short
        return 2
    fi

    printf '[COSYVOICE3-REFERENCE-PROMOTION] updating main before evidence promotion\n'
    git pull --ff-only origin main || return $?
    PUBLICATION_HEAD="$(git rev-parse HEAD)" || return $?

    mkdir -p "$WORK"
    rm -f "$DEVICE_RECEIPT"

    printf '[COSYVOICE3-REFERENCE-PROMOTION] pulling receipt from physical iPhone\n'
    xcrun devicectl device copy from \
        --device "$DEVICE_ID" \
        --domain-type appDataContainer \
        --domain-identifier "$BUNDLE_ID" \
        --source "Documents/reference-smoke-receipt.json" \
        --destination "$DEVICE_RECEIPT" || return $?

    if [ ! -s "$DEVICE_RECEIPT" ]; then
        printf '[COSYVOICE3-REFERENCE-PROMOTION] ERROR device receipt missing/empty after copy\n'
        return 3
    fi

    printf '[COSYVOICE3-REFERENCE-PROMOTION] device receipt:\n'
    cat "$DEVICE_RECEIPT"
    printf '\n'

    "$PYTHON_BIN" "$ROOT/tools/finalize_reference_device_promotion.py" \
        --ios-root "$ROOT" \
        --asset-root "$ASSET_ROOT" \
        --host-receipt "$HOST_RECEIPT" \
        --device-receipt "$DEVICE_RECEIPT" \
        --reference-candidate-dir "$REFERENCE_CANDIDATE_DIR" \
        --listening-acceptance "$LISTENING_ACCEPTANCE" \
        --publication-head "$PUBLICATION_HEAD" || return $?

    printf '[COSYVOICE3-REFERENCE-PROMOTION] tracked changes after validated promotion:\n'
    git status --short

    if [ "$COMMIT_PUSH" = "1" ]; then
        git add \
            ios/manifest.json \
            ios/assets/reference_enrollment.json \
            ios/RELEASE_CHECKLIST.md \
            ios/validation/development_receipt.json \
            ios/validation/reference-device/reference-smoke-receipt.json \
            ios/validation/reference-device/promotion-receipt.json || return $?

        git -c user.name="actacomes" -c user.email="developer@actacomes.com" \
            commit -m "iOS: promote custom reference lane after device parity" || return $?
        git push origin main || return $?
        printf '[COSYVOICE3-REFERENCE-PROMOTION] PUSHED commit=%s\n' "$(git rev-parse HEAD)"
    else
        printf '[COSYVOICE3-REFERENCE-PROMOTION] validated promotion complete; commit/push disabled by COSYVOICE3_PROMOTION_COMMIT_PUSH=%s\n' "$COMMIT_PUSH"
    fi

    printf '[COSYVOICE3-REFERENCE-PROMOTION] PASS referenceStatus=PASS_DEVICE_PARITY overallReleaseStatus=development\n'
}

main "$@"
RC=$?
printf '[COSYVOICE3-REFERENCE-PROMOTION] rc=%s\n' "$RC"
test "$RC" -eq 0

# Code purpose: one-command retrieval, validation, evidence recording, Git commit and push for the physical-device custom-reference promotion.
# Upstream evidence: DeviceSmoke Documents/reference-smoke-receipt.json bound to the current PASS_HOST_PARITY receipt.
# Runtime: macOS + connected trusted iPhone + Python3 + git.
# Generated: 2026-10-02 America/New_York.
