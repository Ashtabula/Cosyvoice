# evaluate_phase1_gate.py
# Requirement: keep dynamic-shape execution, numerical acceptance, and accelerator residency as separate gates; never promote Phase2 from shape execution alone.
from __future__ import annotations
import argparse
import json
from pathlib import Path
from typing import Any


def load(path: Path | None):
    if path is None:
        return None
    return json.loads(path.read_text())


def device_execution_pass(receipt: dict[str, Any]) -> bool:
    expected = {(role, n) for role in ("conditions", "shard0") for n in (186, 225)}
    actual = {(row.get("role"), row.get("N")) for row in receipt.get("tests", [])}
    return (
        receipt.get("physicalDevice") is True
        and actual == expected
        and all(
            row.get("status") == "EXECUTED_NUMERICS_RECORDED_NOT_ACCEPTED"
            and all(metric.get("finite") for metric in (row.get("outputs") or {}).values())
            for row in receipt.get("tests", [])
        )
    )


def preferred_neural_engine(receipt: dict[str, Any]) -> bool:
    counts: dict[str, int] = {}
    for key in ("conditionsComputePlanPreferredCounts", "shard0ComputePlanPreferredCounts"):
        for device, count in (receipt.get(key) or {}).items():
            counts[str(device)] = counts.get(str(device), 0) + int(count)

    for device, count in counts.items():
        name = device.lower().replace("_", " ")
        if count > 0 and (
            "neural" in name
            or " ane" in f" {name}"
            or name.startswith("ane")
        ):
            return True
    return False


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--conditions", type=Path, required=True)
    parser.add_argument("--shard0", type=Path, required=True)
    parser.add_argument("--fixed-control", type=Path, required=True)
    parser.add_argument("--device-cpu", type=Path, required=True)
    parser.add_argument("--device-ne", type=Path, required=True)
    parser.add_argument("--attribution", type=Path)
    parser.add_argument("--hybrid", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    conditions = load(args.conditions)
    shard0 = load(args.shard0)
    fixed = load(args.fixed_control)
    cpu = load(args.device_cpu)
    ne = load(args.device_ne)
    attribution = load(args.attribution)
    hybrid = load(args.hybrid)

    checks = {
        "conditionsSourceSymbolic": conditions.get("symbolicDimensionRetained") is True,
        "shard0SourceSymbolic": shard0.get("symbolicDimensionRetained") is True,
        "conditionsHostMultiLength": (
            conditions.get("status") == "PASS_HOST_SYMBOLIC_CONDITIONS"
            and {row["N"] for row in conditions.get("tests", [])} == {186, 225}
        ),
        "shard0HostExecution": (
            shard0.get("conversion")
            == shard0.get("compilation")
            == shard0.get("loading")
            == "PASS"
            and all(row.get("finite") for row in shard0.get("tests", []))
        ),
        "physicalCPUOnly": device_execution_pass(cpu),
        "physicalCPUAndNEPolicy": device_execution_pass(ne),
        "sameAssetFamilyAcrossBackends": (
            cpu.get("assetIdentity", {}).get("models")
            == ne.get("assetIdentity", {}).get("models")
        ),
    }

    dynamic_shape_execution_pass = all(checks.values())

    frozen_outputs = fixed.get("outputs", fixed)
    legacy_bit_exact = all(
        row.get("dynamicVsFixed", {}).get("finite") is True
        and row.get("dynamicVsFixed", {}).get("maxAbsError") == 0
        for row in frozen_outputs.values()
        if isinstance(row, dict) and "dynamicVsFixed" in row
    )

    attribution_complete = (
        attribution is not None
        and attribution.get("status")
        == "PASS_MATRIX_COMPLETE_NUMERICAL_ACCEPTANCE_UNRESOLVED"
    )
    hybrid_complete = (
        hybrid is not None
        and hybrid.get("status")
        == "PASS_HYBRID_CONTROL_COMPLETE_NUMERICAL_ACCEPTANCE_UNRESOLVED"
    )

    numerical_state = "ATTRIBUTION_PENDING"
    if attribution_complete and hybrid_complete:
        numerical_state = "ATTRIBUTION_COMPLETE_ACCEPTANCE_UNRESOLVED"
    elif attribution is not None or hybrid is not None:
        numerical_state = "ATTRIBUTION_PARTIAL"

    accelerator_residency_pass = preferred_neural_engine(ne)
    residency_state = (
        "PREFERRED_NEURAL_ENGINE_PRESENT_NOT_MEASURED_RESIDENCY"
        if accelerator_residency_pass
        else "NOT_PROVEN_CPU_PREFERRED"
    )

    # Deliberately remain fail-closed. The next evidence pass must establish an explicit
    # numerical acceptance boundary from the apples-to-apples conversion matrix and
    # downstream hybrid control; an intermediate cross-converter h difference alone
    # is not treated as the acceptance criterion.
    numerical_acceptance_pass = False
    phase2_allowed = dynamic_shape_execution_pass and numerical_acceptance_pass

    result = {
        "schemaVersion": 2,
        "status": (
            "HOLD_PHASE1_NUMERICAL_ACCEPTANCE"
            if dynamic_shape_execution_pass
            else "FAIL_PHASE1_DYNAMIC_EXECUTION"
        ),
        "checks": checks,
        "trueDynamicShapeFeasible": dynamic_shape_execution_pass,
        "dynamicShapeExecutionPass": dynamic_shape_execution_pass,
        "legacyIntermediateBitExactControl": legacy_bit_exact,
        "numericalAttributionComplete": attribution_complete and hybrid_complete,
        "numericalAcceptanceState": numerical_state,
        "numericalAcceptancePass": numerical_acceptance_pass,
        "acceleratorResidencyState": residency_state,
        "acceleratorResidencyPass": accelerator_residency_pass,
        "phase2Allowed": phase2_allowed,
        "phase3Allowed": False,
        "phase4Allowed": False,
        "phase5Allowed": False,
        "gateReason": (
            "Dynamic multi-length execution is a separate success. "
            "Phase2 remains blocked until the N225 conversion matrix and downstream "
            "hybrid control establish a justified numerical acceptance boundary."
        ),
        "acceptanceBoundaryNote": (
            "Frozen release bit-exact evidence compares accepted Core ML monolithic "
            "FP16 with accepted Core ML sharded FP16. It does not by itself define a "
            "cross-converter tolerance for an intermediate shard0 h tensor."
        ),
        "realLLM186Workload": "NOT_RUN",
        "fullDynamicPCM": "NOT_RUN",
    }

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps(result, indent=2, sort_keys=True), flush=True)
    return 0 if phase2_allowed else 1


if __name__ == "__main__":
    raise SystemExit(main())


# Code purpose: preserve true dynamic execution evidence while failing closed on unresolved numerical acceptance and unproven accelerator residency.
# Upstream source: Phase1 symbolic host/device receipts plus optional conversion-attribution and hybrid downstream receipts.
# Runtime environment: Python 3 standard library.
# Generated time: 2026-10-03 America/New_York.
# Changes: split execution/numerics/residency gates; remove the incorrect implication that frozen full-vs-sharded bit identity automatically defines a cross-converter shard0-h acceptance rule.
