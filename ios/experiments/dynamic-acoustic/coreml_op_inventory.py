# coreml_op_inventory.py
# Requirement: inventory serialized Core ML ML Program operation types so converter-path differences are recorded instead of inferred only from final tensors.
from __future__ import annotations
from collections import Counter
from pathlib import Path
from typing import Any
import coremltools as ct


def _child_blocks(operation: Any):
    blocks = getattr(operation, "blocks", None)
    if blocks is None:
        return []
    if hasattr(blocks, "values"):
        return list(blocks.values())
    try:
        return list(blocks)
    except TypeError:
        return []


def _walk_block(block: Any, counts: Counter[str], depth: int = 0) -> tuple[int, int]:
    total = 0
    maximum_depth = depth
    for operation in getattr(block, "operations", []):
        op_type = str(getattr(operation, "type", "<unknown>"))
        counts[op_type] += 1
        total += 1
        for child in _child_blocks(operation):
            child_total, child_depth = _walk_block(child, counts, depth + 1)
            total += child_total
            maximum_depth = max(maximum_depth, child_depth)
    return total, maximum_depth


def inventory_package(package: Path) -> dict[str, Any]:
    result: dict[str, Any] = {"status": "RUNNING", "package": str(package)}
    try:
        model = ct.models.MLModel(str(package), skip_model_load=True)
        spec = model.get_spec()
        program = getattr(spec, "mlProgram", None)
        if program is None:
            raise RuntimeError("model does not expose an ML Program")
        counts: Counter[str] = Counter()
        total = 0
        max_depth = 0
        functions = []
        for function_name, function in program.functions.items():
            specializations = getattr(function, "block_specializations", None)
            if specializations is None:
                raise RuntimeError(f"function {function_name} has no block_specializations")
            rows = []
            for specialization, block in specializations.items():
                block_counts: Counter[str] = Counter()
                block_total, block_depth = _walk_block(block, block_counts)
                counts.update(block_counts)
                total += block_total
                max_depth = max(max_depth, block_depth)
                rows.append(
                    {
                        "specialization": str(specialization),
                        "operationCount": block_total,
                        "maxNestedBlockDepth": block_depth,
                        "operationTypeCounts": dict(sorted(block_counts.items())),
                    }
                )
            functions.append({"name": str(function_name), "specializations": rows})
        result.update(
            {
                "status": "PASS",
                "operationCount": total,
                "maxNestedBlockDepth": max_depth,
                "operationTypeCounts": dict(sorted(counts.items())),
                "functions": functions,
            }
        )
    except Exception as exc:
        result.update({"status": "FAIL", "error": str(exc), "exceptionType": type(exc).__name__})
    return result


def diff_inventories(left: dict[str, Any], right: dict[str, Any]) -> dict[str, Any]:
    a = Counter(left.get("operationTypeCounts") or {})
    b = Counter(right.get("operationTypeCounts") or {})
    names = sorted(set(a) | set(b))
    delta = {name: int(b[name] - a[name]) for name in names if b[name] != a[name]}
    return {
        "leftStatus": left.get("status"),
        "rightStatus": right.get("status"),
        "leftOperationCount": left.get("operationCount"),
        "rightOperationCount": right.get("operationCount"),
        "operationTypeDeltaRightMinusLeft": delta,
    }


# Code purpose: record Core ML operation-level differences for the dynamic acoustic attribution matrix.
# Upstream source: serialized frozen/experimental Core ML ML Program packages.
# Runtime environment: Python 3.11 + coremltools 9.
# Generated time: 2026-10-03 America/New_York.
# Changes: new experiment-only helper; no shipping runtime changes.
