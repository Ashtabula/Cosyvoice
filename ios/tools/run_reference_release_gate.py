#!/usr/bin/env python3
# Requirement: run all host-side custom-reference promotion gates and emit one machine-readable receipt.
from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path


def run(command: list[str | Path], *, cwd: Path | None = None, env: dict[str, str] | None = None) -> None:
    values = [str(value) for value in command]
    print("[COSYVOICE3-REFERENCE-GATE] RUN " + " ".join(values), flush=True)
    subprocess.run(values, check=True, cwd=cwd, env=env)


def load(path: Path) -> dict:
    return json.loads(path.read_text())


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--model-dir", type=Path, required=True)
    parser.add_argument("--coreml-dir", type=Path, required=True)
    parser.add_argument("--work", type=Path, required=True)
    args = parser.parse_args()

    here = Path(__file__).resolve().parent
    package_root = here.parent
    work = args.work.resolve()
    fixture = work / "fixture"
    work.mkdir(parents=True, exist_ok=True)

    run([sys.executable, here / "generate_reference_parity_fixture.py", "--output", fixture])
    run([sys.executable, here / "export_reference_frontend_tables.py", "--output", fixture])

    swift_receipt = work / "swift_dsp_parity.json"
    swift_env = dict(os.environ)
    swift_env["COSYVOICE3_REFERENCE_PARITY_FIXTURE"] = str(fixture)
    swift_env["COSYVOICE3_REFERENCE_PARITY_RECEIPT"] = str(swift_receipt)
    run(
        ["swift", "test", "--package-path", package_root, "--filter", "ReferenceDSPExternalParityTests"],
        cwd=package_root.parent,
        env=swift_env,
    )

    learned = work / "reference_coreml_parity.json"
    flow = work / "dynamic_flow_conditions_parity.json"
    run([
        sys.executable, here / "validate_reference_coreml_parity.py",
        "--upstream-model-dir", args.model_dir,
        "--coreml-dir", args.coreml_dir,
        "--fixture", fixture,
        "--output", learned,
    ])
    run([
        sys.executable, here / "validate_dynamic_flow_conditions_parity.py",
        "--source-root", args.source_root,
        "--model-dir", args.model_dir,
        "--coreml", args.coreml_dir / "flow-conditions-dynamic-151-302.mlpackage",
        "--output", flow,
    ])

    swift_value = load(swift_receipt)
    learned_value = load(learned)
    flow_value = load(flow)
    passed = (
        swift_value.get("status") == "PASS"
        and learned_value.get("status") == "PASS"
        and flow_value.get("status") == "PASS"
    )
    receipt = {
        "schemaVersion": 2,
        "status": "PASS_HOST_PARITY" if passed else "FAIL",
        "sourceCommit": "878940245562bcd1dd0231d78157ba78d70b39f6",
        "modelRevision": "29e01c4e8d000f4bcd70751be16fa94bf3d85a18",
        "fixture": str(fixture / "reference_fixture.json"),
        "swiftDSPParity": {"path": str(swift_receipt), "sha256": sha256(swift_receipt)},
        "referenceCoreMLParity": {"path": str(learned), "sha256": sha256(learned)},
        "dynamicFlowParity": {"path": str(flow), "sha256": sha256(flow)},
        "promotionState": "HOST_PARITY_COMPLETE_DEVICE_PARITY_PENDING" if passed else "BLOCKED",
    }
    output = work / "reference_host_parity_receipt.json"
    output.write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt, indent=2))
    if not passed:
        raise SystemExit(2)


if __name__ == "__main__":
    main()

# Code purpose: one-command host-side native DSP + learned-model + dynamic-Flow reference parity gate.
# Runtime: macOS validation host.
# Generated: 2026-10-02 America/New_York.
