#!/usr/bin/env python3
# Requirement: run all host-side custom-reference promotion gates and emit one machine-readable receipt.
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path


def run(command: list[str | Path]) -> None:
    values = [str(value) for value in command]
    print("[COSYVOICE3-REFERENCE-GATE] RUN " + " ".join(values), flush=True)
    subprocess.run(values, check=True)


def load(path: Path) -> dict:
    return json.loads(path.read_text())


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--model-dir", type=Path, required=True)
    parser.add_argument("--coreml-dir", type=Path, required=True)
    parser.add_argument("--work", type=Path, required=True)
    args = parser.parse_args()

    here = Path(__file__).resolve().parent
    work = args.work.resolve()
    fixture = work / "fixture"
    work.mkdir(parents=True, exist_ok=True)

    run([sys.executable, here / "generate_reference_parity_fixture.py", "--output", fixture])
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

    learned_value = load(learned)
    flow_value = load(flow)
    passed = learned_value.get("status") == "PASS" and flow_value.get("status") == "PASS"
    receipt = {
        "schemaVersion": 1,
        "status": "PASS_HOST_PARITY" if passed else "FAIL",
        "fixture": str(fixture / "reference_fixture.json"),
        "referenceCoreMLParity": str(learned),
        "dynamicFlowParity": str(flow),
        "promotionState": "HOST_PARITY_COMPLETE_DEVICE_PARITY_PENDING" if passed else "BLOCKED",
    }
    output = work / "reference_host_parity_receipt.json"
    output.write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt, indent=2))
    if not passed:
        raise SystemExit(2)


if __name__ == "__main__":
    main()

# Code purpose: one-command host-side reference parity gate.
# Runtime: macOS validation host.
# Generated: 2026-10-02 America/New_York.
