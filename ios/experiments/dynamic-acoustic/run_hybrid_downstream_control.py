# run_hybrid_downstream_control.py
# Requirement: measure whether dynamic conditions and/or dynamic shard0 perturb the final first-call velocity after accepted frozen shards1-5, using identical N225 fixture bytes.
from __future__ import annotations
import argparse
import json
import traceback
from pathlib import Path
from typing import Any

import coremltools as ct
import numpy as np
import torch

from probe_symbolic_conditions import sha
from run_shard0_attribution import metrics


def load_manifest(asset_root: Path):
    path = asset_root / "cosyvoice3_fixed225.json"
    value = json.loads(path.read_text())
    shards = [asset_root / item for item in value.get("flowShards") or []]
    if len(shards) != 6:
        raise RuntimeError("fixed manifest must declare six Flow shards")
    reference = value.get("referenceEnrollment") or {}
    relative_conditions = reference.get("flowConditionsDynamic")
    if not relative_conditions:
        raise RuntimeError("fixed manifest has no custom-reference Flow conditions package")
    return path, asset_root / relative_conditions, shards


def load_array(folder: Path, name: str, shape: tuple[int, ...], dtype=np.float32):
    value = np.fromfile(folder / f"{name}.bin", dtype=dtype)
    if value.size != int(np.prod(shape)):
        raise RuntimeError(f"{name} size mismatch {value.size} != {int(np.prod(shape))}")
    return value.reshape(shape)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixed-asset-root", type=Path, required=True)
    parser.add_argument("--dynamic-conditions-package", type=Path, required=True)
    parser.add_argument("--dynamic-shard0-package", type=Path, required=True)
    parser.add_argument("--conditions-fixture", type=Path, required=True)
    parser.add_argument("--shard-fixture", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    args.output.parent.mkdir(parents=True, exist_ok=True)
    receipt: dict[str, Any] = {
        "schemaVersion": 1,
        "status": "RUNNING",
        "phase": "load",
        "variants": {},
    }

    def save():
        args.output.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")

    save()
    try:
        manifest_path, fixed_conditions_path, fixed_shards = load_manifest(args.fixed_asset_root)
        receipt["assetIdentity"] = {
            "manifestSha256": sha(manifest_path),
            "fixedConditionsSha256": sha(fixed_conditions_path),
            "fixedShardSha256": [sha(path) for path in fixed_shards],
            "dynamicConditionsSha256": sha(args.dynamic_conditions_package),
            "dynamicShard0Sha256": sha(args.dynamic_shard0_package),
        }

        cond_shapes = {
            "tokens": (1, 225),
            "prompt_tokens": (1, 151),
            "prompt_feat": (1, 302, 80),
            "speaker": (1, 192),
        }
        cond_feed = {
            name: load_array(
                args.conditions_fixture,
                name,
                shape,
                np.int32 if name in {"tokens", "prompt_tokens"} else np.float32,
            )
            for name, shape in cond_shapes.items()
        }

        shard_feed_base = {
            "x": load_array(args.shard_fixture, "x", (2, 80, 752)),
            "mask": load_array(args.shard_fixture, "mask", (2, 1, 752)),
            "t": load_array(args.shard_fixture, "t", (2,)),
        }

        receipt["fixtureSha256"] = {
            "conditions": {
                name: sha(args.conditions_fixture / f"{name}.bin") for name in cond_shapes
            },
            "shard": {
                name: sha(args.shard_fixture / f"{name}.bin") for name in shard_feed_base
            },
        }

        fixed_conditions = ct.models.MLModel(
            str(fixed_conditions_path),
            compute_units=ct.ComputeUnit.CPU_ONLY,
        )
        dynamic_conditions = ct.models.MLModel(
            str(args.dynamic_conditions_package),
            compute_units=ct.ComputeUnit.CPU_ONLY,
        )
        fixed_models = [
            ct.models.MLModel(str(path), compute_units=ct.ComputeUnit.CPU_ONLY)
            for path in fixed_shards
        ]
        dynamic_shard0 = ct.models.MLModel(
            str(args.dynamic_shard0_package),
            compute_units=ct.ComputeUnit.CPU_ONLY,
        )

        fixed_cond = fixed_conditions.predict(cond_feed)
        dynamic_cond = dynamic_conditions.predict(cond_feed)
        cond_names = ("mu", "spks", "cond")
        receipt["dynamicConditionsVsFrozen"] = {
            name: metrics(fixed_cond[name], dynamic_cond[name]) for name in cond_names
        }

        official = torch.load(
            args.fixture / "estimator_00.pt",
            weights_only=True,
        )["output"].cpu().numpy()

        def run(first_model, conditioning):
            first_feed = {
                "x": shard_feed_base["x"],
                "mask": shard_feed_base["mask"],
                "mu": conditioning["mu"],
                "t": shard_feed_base["t"],
                "spks": conditioning["spks"],
                "cond": conditioning["cond"],
            }
            first = first_model.predict(first_feed)
            feed = {
                "h": first["h"],
                "te": first["te"],
                "mask": shard_feed_base["mask"],
            }
            for model in fixed_models[1:-1]:
                value = model.predict(feed)
                feed["h"] = value["h_out"]
            final = fixed_models[-1].predict(feed)["velocity"]
            return first, final

        definitions = {
            "A_frozenConditions_frozenShard0": (fixed_models[0], fixed_cond),
            "B_dynamicConditions_frozenShard0": (fixed_models[0], dynamic_cond),
            "C_frozenConditions_dynamicShard0": (dynamic_shard0, fixed_cond),
            "D_dynamicConditions_dynamicShard0": (dynamic_shard0, dynamic_cond),
        }

        outputs = {}
        first_outputs = {}

        for name, (first_model, conditioning) in definitions.items():
            receipt["phase"] = name
            save()

            first, velocity = run(first_model, conditioning)
            outputs[name] = velocity
            first_outputs[name] = first

            receipt["variants"][name] = {
                "status": "EXECUTED_NUMERICS_RECORDED_NOT_ACCEPTED",
                "velocityVsOfficial": metrics(official, velocity),
            }

        baseline = outputs["A_frozenConditions_frozenShard0"]

        for name in definitions:
            receipt["variants"][name]["velocityVsFrozenBaselineA"] = metrics(
                baseline,
                outputs[name],
            )
            receipt["variants"][name]["shard0HVsBaselineA"] = metrics(
                first_outputs["A_frozenConditions_frozenShard0"]["h"],
                first_outputs[name]["h"],
            )
            receipt["variants"][name]["shard0TeVsBaselineA"] = metrics(
                first_outputs["A_frozenConditions_frozenShard0"]["te"],
                first_outputs[name]["te"],
            )

        receipt["phase"] = "complete"
        receipt["status"] = "PASS_HYBRID_CONTROL_COMPLETE_NUMERICAL_ACCEPTANCE_UNRESOLVED"
        receipt["acceptance"] = "UNRESOLVED_BY_DESIGN"

    except Exception as exc:
        receipt["status"] = "FAIL"
        receipt["error"] = str(exc)
        receipt["exceptionType"] = type(exc).__name__
        receipt["traceback"] = traceback.format_exc()

    finally:
        save()
        print(json.dumps(receipt, indent=2, sort_keys=True), flush=True)
        print(f"[COSYVOICE3-DYNAMIC-HYBRID] receipt={args.output}", flush=True)

    return (
        0
        if receipt.get("status")
        == "PASS_HYBRID_CONTROL_COMPLETE_NUMERICAL_ACCEPTANCE_UNRESOLVED"
        else 1
    )


if __name__ == "__main__":
    raise SystemExit(main())


# Code purpose: determine whether Phase1 conversion drift survives accepted downstream shards1-5 instead of judging only an intermediate h tensor.
# Upstream source: accepted fixed225 conditions/shards and the experiment symbolic conditions/shard0 package.
# Runtime environment: macOS CPU_ONLY Core ML + Python 3.11.
# Generated time: 2026-10-03 America/New_York.
# Changes: new N225 hybrid first-call control; does not export or modify shards1-5.
