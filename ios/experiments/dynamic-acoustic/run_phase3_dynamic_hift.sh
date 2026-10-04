#@title run_phase3_dynamic_hift.sh
# Requirement: run true-dynamic HiFT body host validation only after complete six-shard dynamic Flow host execution passed; preserve all failed work directories and keep production promotion closed.
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
EXP="$ROOT/ios/experiments/dynamic-acoustic"
PYTHON="${COSYVOICE3_DYNAMIC_PYTHON:-$ROOT/ios/.work/dynamic-acoustic/venv/bin/python}"
SOURCE="${COSYVOICE3_DYNAMIC_SOURCE:-$ROOT/ios/.work/rebuild/ios-fixed225-reference/source}"
MODEL="${COSYVOICE3_DYNAMIC_MODEL:-$ROOT/ios/.work/rebuild/ios-fixed225-reference/model-cache/Fun-CosyVoice3-0.5B-2512}"
FIXTURE="${COSYVOICE3_DYNAMIC_FIXTURE:-$ROOT/ios/.work/rebuild/ios-fixed225-reference/fixture}"
WORK="${COSYVOICE3_PHASE3_WORK:-}"
BRANCH="experiment/ios-dynamic-acoustic"
EVIDENCE="$EXP/evidence/phase3-dynamic-hift-host-v1.json"

find_fixed_asset_root(){
    if [ -n "${COSYVOICE3_FIXED_ASSET_ROOT:-}" ]; then
        printf '%s\n' "$COSYVOICE3_FIXED_ASSET_ROOT"
        return 0
    fi
    for candidate in \
        "$ROOT/ios/.work/production-clean-room/fetched-runtime" \
        "$ROOT/ios/.work/rebuilt-runtime/ios-fixed225-reference" \
        "$ROOT/ios/validation/DeviceSmoke/GeneratedAssets/Runtime"
    do
        if [ -f "$candidate/cosyvoice3_fixed225.json" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

main(){
    command -v git
    command -v xcrun

    [ "$(git -C "$ROOT" branch --show-current)" = "$BRANCH" ] || {
        echo "[COSYVOICE3-DYNAMIC-PHASE3] ERROR wrong branch"
        return 2
    }

    [ -x "$PYTHON" ] || {
        echo "[COSYVOICE3-DYNAMIC-PHASE3] ERROR missing Python: $PYTHON"
        return 2
    }

    [ -z "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ] || {
        echo "[COSYVOICE3-DYNAMIC-PHASE3] ERROR tracked worktree must be clean"
        git -C "$ROOT" status --short
        return 2
    }


    echo "[COSYVOICE3-DYNAMIC-PHASE3] VERIFY PINNED PYTHON DEPENDENCIES"
    if ! "$PYTHON" - <<'PY'
import importlib
import importlib.metadata as md

required = {
    "HyperPyYAML": "1.2.3",
    "omegaconf": "2.3.0",
    "scipy": "1.13.1",
    "transformers": "4.51.3",
}

modules = {
    "HyperPyYAML": "hyperpyyaml",
    "omegaconf": "omegaconf",
    "scipy": "scipy",
    "transformers": "transformers",
}

problems = []
for distribution, expected in required.items():
    try:
        actual = md.version(distribution)
        importlib.import_module(modules[distribution])
    except Exception as exc:
        problems.append(f"{distribution}: missing/import failed: {exc}")
        continue
    if actual != expected:
        problems.append(f"{distribution}: {actual} != {expected}")

if problems:
    print("[COSYVOICE3-DYNAMIC-PHASE3] dependency preflight failed")
    for problem in problems:
        print(" -", problem)
    raise SystemExit(1)

for distribution, expected in required.items():
    print(f"[COSYVOICE3-DYNAMIC-PHASE3] dependency {distribution}={expected}")
PY
    then
        echo "[COSYVOICE3-DYNAMIC-PHASE3] installing pinned Phase3 dependencies from experiment requirements"
        "$PYTHON" -m pip install             --disable-pip-version-check             "HyperPyYAML==1.2.3"             "omegaconf==2.3.0"             "scipy==1.13.1"             "transformers==4.51.3"

        "$PYTHON" - <<'PY'
import importlib.metadata as md
for name in ("HyperPyYAML", "omegaconf", "scipy", "transformers"):
    print(f"[COSYVOICE3-DYNAMIC-PHASE3] installed {name}={md.version(name)}")
PY
    fi

    "$PYTHON" - <<'PY'
import json
from pathlib import Path
phase2 = json.loads(
    Path("ios/experiments/dynamic-acoustic/evidence/phase2-dynamic-flow-host-v1.json").read_text()
)
expected = "PASS_PHASE2_HOST_DYNAMIC_FLOW_EXECUTION_NUMERICS_RECORDED_NOT_PROMOTED"
if phase2.get("status") != expected:
    raise SystemExit(
        f"Phase3 blocked: Phase2 status={phase2.get('status')!r}, expected={expected!r}"
    )
tests = phase2.get("tests") or []
pairs = {(row.get("N"), row.get("G"), row.get("T")) for row in tests}
if pairs != {(186,372,674),(225,450,752)}:
    raise SystemExit(f"Phase3 blocked: unexpected Phase2 geometry {pairs}")
if not all(row.get("finite") for row in tests):
    raise SystemExit("Phase3 blocked: Phase2 contains non-finite output")
print("[COSYVOICE3-DYNAMIC-PHASE3] phase2EntryBasis=PASS")
print("[COSYVOICE3-DYNAMIC-PHASE3] note=Flow dynamic execution passed; production promotion remains closed")
PY

    if [ -z "$WORK" ]; then
        local candidate_index
        for candidate_index in $(seq 1 99); do
            local candidate="$ROOT/ios/.work/dynamic-acoustic/phase3-dynamic-hift-v$candidate_index"
            if [ ! -e "$candidate" ]; then
                WORK="$candidate"
                break
            fi
        done
    fi

    [ -n "$WORK" ] || {
        echo "[COSYVOICE3-DYNAMIC-PHASE3] ERROR could not allocate work directory"
        return 2
    }

    [ ! -e "$WORK" ] || {
        echo "[COSYVOICE3-DYNAMIC-PHASE3] ERROR work directory already exists: $WORK"
        return 2
    }

    local fixed
    fixed="$(find_fixed_asset_root)" || {
        echo "[COSYVOICE3-DYNAMIC-PHASE3] ERROR set COSYVOICE3_FIXED_ASSET_ROOT"
        return 2
    }

    echo "[COSYVOICE3-DYNAMIC-PHASE3] root=$ROOT"
    echo "[COSYVOICE3-DYNAMIC-PHASE3] head=$(git -C "$ROOT" rev-parse HEAD)"
    echo "[COSYVOICE3-DYNAMIC-PHASE3] work=$WORK"
    echo "[COSYVOICE3-DYNAMIC-PHASE3] fixedAssetRoot=$fixed"

    "$PYTHON" "$EXP/run_phase3_dynamic_hift.py" \
        --source-root "$SOURCE" \
        --model-dir "$MODEL" \
        --fixture "$FIXTURE" \
        --fixed-asset-root "$fixed" \
        --output "$WORK"

    cp "$WORK/receipt.json" "$EVIDENCE"

    "$PYTHON" "$EXP/refresh_evidence_index.py" \
        --evidence-dir "$EXP/evidence"

    echo "===== PHASE 3 SUMMARY ====="
    "$PYTHON" - <<'PY'
import json
from pathlib import Path

r = json.loads(
    Path("ios/experiments/dynamic-acoustic/evidence/phase3-dynamic-hift-host-v1.json").read_text()
)

print("status =", r.get("status"))
print("dynamicHiFTBodyHostPass =", r.get("dynamicHiFTBodyHostPass"))
print("packageSha256 =", (r.get("dynamicPackage") or {}).get("packageSha256"))
print("melFramesSymbolic =", (r.get("dynamicPackage") or {}).get("melFramesSymbolic"))
print("sampleCountSymbolic =", (r.get("dynamicPackage") or {}).get("sampleCountSymbolic"))

for row in r.get("tests") or []:
    print()
    print("G =", row.get("G"), "expectedSamples =", row.get("expectedSamples"))
    m = row.get("dynamicCoreMLVsSourceBody") or {}
    u = row.get("dynamicCoreMLShippingPathVsUpstream") or {}
    print(
        "dynamicCoreMLVsSourceBody",
        "maxAbs=", m.get("maxAbsError"),
        "rmse=", m.get("rmse"),
        "relativeL2=", m.get("relativeL2"),
        "cosine=", m.get("cosineSimilarity"),
    )
    print(
        "dynamicCoreMLShippingPathVsUpstream",
        "maxAbs=", u.get("maxAbsError"),
        "rmse=", u.get("rmse"),
        "relativeL2=", u.get("relativeL2"),
        "cosine=", u.get("cosineSimilarity"),
    )
    if row.get("G") == 450:
        f = row.get("dynamicCoreMLVsFrozenCoreML") or {}
        print(
            "dynamicCoreMLVsFrozenCoreML",
            "maxAbs=", f.get("maxAbsError"),
            "rmse=", f.get("rmse"),
            "relativeL2=", f.get("relativeL2"),
            "cosine=", f.get("cosineSimilarity"),
        )

print()
print("productionPromotion =", r.get("productionPromotion"))
PY

    git -C "$ROOT" diff --check
    git -C "$ROOT" config user.name "actacomes"
    git -C "$ROOT" config user.email "developer@actacomes.com"

    git -C "$ROOT" add \
        ios/experiments/dynamic-acoustic/evidence/phase3-dynamic-hift-host-v1.json \
        ios/experiments/dynamic-acoustic/evidence/evidence-index.json

    git -C "$ROOT" diff --cached --check
    git -C "$ROOT" diff --cached --stat

    if git -C "$ROOT" diff --cached --quiet; then
        echo "[COSYVOICE3-DYNAMIC-PHASE3] no new evidence to commit"
    else
        git -C "$ROOT" commit \
            -m "experiment(ios): record true-dynamic HiFT host evidence"
    fi

    git -C "$ROOT" push origin "$BRANCH"

    local local_head remote_head
    local_head="$(git -C "$ROOT" rev-parse HEAD)"
    remote_head="$(git -C "$ROOT" ls-remote origin "refs/heads/$BRANCH" | awk '{print $1}')"

    echo "[COSYVOICE3-DYNAMIC-PHASE3] local=$local_head"
    echo "[COSYVOICE3-DYNAMIC-PHASE3] remote=$remote_head"

    [ "$local_head" = "$remote_head" ] || {
        echo "[COSYVOICE3-DYNAMIC-PHASE3] ERROR remote HEAD mismatch"
        return 2
    }

    echo "[COSYVOICE3-DYNAMIC-PHASE3] COMPLETE"
}

main "$@"

# Code purpose: validate one true-dynamic HiFT body package at G372/G450 and preserve machine-readable evidence before any shipping-runtime integration.
# Upstream source: Ashtabula/Cosyvoice experiment/ios-dynamic-acoustic and CosyVoice3_NPU@878940245562bcd1dd0231d78157ba78d70b39f6.
# Runtime environment: macOS arm64, isolated Python3.11/torch2.7/coremltools9, Core ML CPU_ONLY host validation.
# Generated time: 2026-10-03 America/New_York.
# Changes: experiment-only Phase3 runner; no shipping runtime, LLM cap/EOS, Candidate evidence, or public asset changes.
# Changes 2026-10-03: add exact Phase3 dependency preflight/bootstrap for HyperPyYAML 1.2.3, omegaconf 2.3.0, scipy 1.13.1, and transformers 4.51.3, matching the accepted upstream environment before HiFT construction.
