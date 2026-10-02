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


def run_gate(command: list[str | Path], *, cwd: Path | None = None, env: dict[str, str] | None = None) -> int:
    values = [str(value) for value in command]
    print("[COSYVOICE3-REFERENCE-GATE] RUN " + " ".join(values), flush=True)
    result = subprocess.run(values, check=False, cwd=cwd, env=env)
    if result.returncode != 0:
        print(
            f"[COSYVOICE3-REFERENCE-GATE] SUBGATE_FAIL rc={result.returncode}: "
            + " ".join(values),
            flush=True,
        )
    return result.returncode


def load_or_error(path: Path, stage: str, return_code: int) -> dict:
    if path.is_file():
        try:
            return json.loads(path.read_text())
        except Exception as exc:
            return {
                "status": "ERROR",
                "stage": stage,
                "returnCode": return_code,
                "receiptError": repr(exc),
            }
    return {
        "status": "ERROR",
        "stage": stage,
        "returnCode": return_code,
        "receiptError": f"missing receipt: {path}",
    }


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

    run([sys.executable, here / "generate_reference_parity_fixture.py", "--output", fixture, "--source-root", args.source_root])
    run([sys.executable, here / "export_reference_frontend_tables.py", "--output", fixture])

    swift_receipt = work / "swift_dsp_parity.json"
    swift_camp_fbank = work / "swift_campplus_fbank.f32"
    swift_env = dict(os.environ)
    swift_env["COSYVOICE3_REFERENCE_PARITY_FIXTURE"] = str(fixture)
    swift_env["COSYVOICE3_REFERENCE_PARITY_RECEIPT"] = str(swift_receipt)
    swift_env["COSYVOICE3_SWIFT_CAMPPLUS_FBANK"] = str(swift_camp_fbank)
    swift_rc = run_gate(
        ["swift", "test", "--package-path", package_root, "--filter", "ReferenceDSPExternalParityTests"],
        cwd=package_root.parent,
        env=swift_env,
    )

    learned = work / "reference_coreml_parity.json"
    flow = work / "dynamic_flow_conditions_parity.json"
    learned_rc = run_gate([
        sys.executable, here / "validate_reference_coreml_parity.py",
        "--upstream-model-dir", args.model_dir,
        "--coreml-dir", args.coreml_dir,
        "--fixture", fixture,
        "--swift-campplus-fbank", swift_camp_fbank,
        "--output", learned,
    ])
    flow_rc = run_gate([
        sys.executable, here / "validate_dynamic_flow_conditions_parity.py",
        "--source-root", args.source_root,
        "--model-dir", args.model_dir,
        "--coreml", args.coreml_dir / "flow-conditions-dynamic-151-302.mlpackage",
        "--output", flow,
    ])

    swift_value = load_or_error(swift_receipt, "swiftDSPParity", swift_rc)
    learned_value = load_or_error(learned, "referenceCoreMLParity", learned_rc)
    flow_value = load_or_error(flow, "dynamicFlowParity", flow_rc)
    passed = (
        swift_rc == 0
        and learned_rc == 0
        and flow_rc == 0
        and swift_value.get("status") == "PASS"
        and learned_value.get("status") == "PASS"
        and flow_value.get("status") == "PASS"
    )
    receipt = {
        "schemaVersion": 2,
        "status": "PASS_HOST_PARITY" if passed else "FAIL",
        "sourceCommit": "878940245562bcd1dd0231d78157ba78d70b39f6",
        "modelRevision": "29e01c4e8d000f4bcd70751be16fa94bf3d85a18",
        "fixture": str(fixture / "reference_fixture.json"),
        "swiftDSPParity": {
            "path": str(swift_receipt),
            "sha256": sha256(swift_receipt) if swift_receipt.is_file() else None,
            "returnCode": swift_rc,
            "status": swift_value.get("status"),
        },
        "referenceCoreMLParity": {
            "path": str(learned),
            "sha256": sha256(learned) if learned.is_file() else None,
            "returnCode": learned_rc,
            "status": learned_value.get("status"),
        },
        "dynamicFlowParity": {
            "path": str(flow),
            "sha256": sha256(flow) if flow.is_file() else None,
            "returnCode": flow_rc,
            "status": flow_value.get("status"),
        },
        "promotionState": "HOST_PARITY_COMPLETE_DEVICE_PARITY_PENDING" if passed else "BLOCKED",
    }
    output = work / "reference_host_parity_receipt.json"
    output.write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt, indent=2))
    if not passed:
        raise SystemExit(2)


if __name__ == "__main__":
    main()

# Code purpose: one-command host-side native DSP + learned-model + dynamic-Flow reference parity gate. Independent parity subgates all run even when an earlier subgate fails, so one invocation reports every blocker.
# Runtime: macOS validation host.
# Generated: 2026-10-02 America/New_York.
