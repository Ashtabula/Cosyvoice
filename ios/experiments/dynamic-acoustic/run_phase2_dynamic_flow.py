# run_phase2_dynamic_flow.py
# Requirement: export all six Flow shards with one genuine symbolic T contract, validate T674/T752 through the same packages, and run a natural-length 6-step cosine CFG Euler rollout without modifying shipping runtime/assets.
from __future__ import annotations

import argparse
import json
import math
import subprocess
import sys
import traceback
from pathlib import Path
from typing import Any

import coremltools as ct
import numpy as np
import torch
import yaml
from torch import nn

from coreml_op_inventory import inventory_package
from probe_symbolic_conditions import PIN, ROOT, SymbolicConditions, extract, sha
from run_shard0_attribution import metrics

sys.path.insert(0, str(ROOT / "ios/tools"))
from reference_flow_conditions import load_reference_flow_conditioning


CUTS = ((0, 4), (4, 8), (8, 12), (12, 16), (16, 20), (20, 22))
OUTPUT_NAMES = ("h", "h_out", "h_out", "h_out", "h_out", "velocity")


def load_estimator(source_root: Path, model_dir: Path):
    sys.path.insert(0, str(source_root.resolve()))
    from cosyvoice.flow.DiT.dit import DiT

    config = yaml.load(
        (model_dir / "cosyvoice3.yaml").read_text(),
        Loader=yaml.BaseLoader,
    )["flow"]["decoder"]["estimator"]
    keys = (
        "dim",
        "depth",
        "heads",
        "dim_head",
        "ff_mult",
        "mel_dim",
        "mu_dim",
        "spk_dim",
        "out_channels",
    )
    estimator = DiT(
        **{key: int(config[key]) for key in keys},
        static_chunk_size=50,
        num_decoding_left_chunks=-1,
    ).eval()
    weights = torch.load(
        model_dir / "flow.pt",
        weights_only=True,
        map_location="cpu",
        mmap=True,
    )
    prefix = "decoder.estimator."
    estimator.load_state_dict(
        {
            key[len(prefix) :]: value
            for key, value in weights.items()
            if key.startswith(prefix)
        },
        strict=True,
    )
    return estimator


def load_full_graph(source_root: Path, estimator):
    namespace = {"torch": torch, "math": math}
    extract(
        source_root,
        "iOS/tools/flow_graphs.py",
        ["BroadcastMaskDiTGraph"],
        namespace,
    )
    return namespace["BroadcastMaskDiTGraph"](estimator).eval()


def load_shards(source_root: Path, estimator):
    namespace = {"nn": nn}
    extract(
        source_root,
        "iOS/tools/export_flow_fp16_shards.py",
        ["FirstShard", "MiddleShard", "FinalShard"],
        namespace,
    )
    shards = [namespace["FirstShard"](estimator, *CUTS[0]).eval()]
    shards.extend(
        namespace["MiddleShard"](estimator, *pair).eval()
        for pair in CUTS[1:-1]
    )
    shards.append(namespace["FinalShard"](estimator, *CUTS[-1]).eval())
    return shards


def load_fixed(asset_root: Path):
    manifest_path = asset_root / "cosyvoice3_fixed225.json"
    manifest = json.loads(manifest_path.read_text())
    shard_paths = [asset_root / item for item in manifest.get("flowShards") or []]
    if len(shard_paths) != 6:
        raise RuntimeError("fixed manifest does not declare six Flow shards")
    reference = manifest.get("referenceEnrollment") or {}
    conditions_relative = reference.get("flowConditionsDynamic")
    if not conditions_relative:
        raise RuntimeError("fixed manifest has no dynamic-reference conditions package")
    return manifest_path, asset_root / conditions_relative, shard_paths


def natural_inputs(
    n: int,
    conditioning: SymbolicConditions,
    flow_fixture: dict[str, torch.Tensor],
    frozen_args,
):
    total = 302 + 2 * n
    with torch.no_grad():
        mu, spks, cond = conditioning(
            flow_fixture["token"][:, :n].int(),
            flow_fixture["prompt_token"].int(),
            flow_fixture["prompt_feat"].float(),
            flow_fixture["embedding"].float(),
        )
    noise = frozen_args[0][0:1, :, :total].contiguous()
    mask = torch.ones(2, 1, total, dtype=mu.dtype)
    return {
        "N": n,
        "G": 2 * n,
        "P": 302,
        "T": total,
        "mu": mu,
        "spks": spks,
        "cond": cond,
        "noise": noise,
        "mask": mask,
    }


def source_first_call(full_graph, shards, case):
    t = torch.zeros(2, dtype=case["mu"].dtype)
    batch_x = case["noise"].repeat(2, 1, 1)
    args = (
        batch_x,
        case["mask"],
        case["mu"],
        t,
        case["spks"],
        case["cond"],
    )
    with torch.no_grad():
        official = full_graph(*args)
        h, te = shards[0](*args)
        boundaries = [{"h": h.detach().clone(), "te": te.detach().clone()}]
        for shard in shards[1:-1]:
            h = shard(h, te, case["mask"])
            boundaries.append({"h": h.detach().clone()})
        sharded = shards[-1](h, te, case["mask"])
    return args, official, sharded, boundaries


def export_package(shard, index: int, example, output_dir: Path, precision):
    if index == 0:
        frame = torch.export.Dim("flow_frames", min=674, max=752)
        dynamic_shapes = ({2: frame}, {2: frame}, {2: frame}, {}, {}, {2: frame})
        input_names = ("x", "mask", "mu", "t", "spks", "cond")
        output_names = ("h", "te")
    else:
        frame = torch.export.Dim("flow_frames", min=674, max=752)
        dynamic_shapes = ({1: frame}, {}, {2: frame})
        input_names = ("h", "te", "mask")
        output_names = ("velocity",) if index == 5 else ("h_out",)

    exported = torch.export.export(
        shard,
        example,
        dynamic_shapes=dynamic_shapes,
        strict=False,
    )
    if exported.dialect == "TRAINING":
        exported = exported.run_decompositions({})

    if index == 0:
        node = next(
            item
            for item in exported.graph.nodes
            if item.op == "placeholder" and item.name == "x"
        )
        symbolic = isinstance(node.meta["val"].shape[2], torch.SymInt)
    else:
        node = next(
            item
            for item in exported.graph.nodes
            if item.op == "placeholder" and item.name == "h"
        )
        symbolic = isinstance(node.meta["val"].shape[1], torch.SymInt)

    if not symbolic:
        raise RuntimeError(f"shard {index} materialized T during torch.export")

    shard_dir = output_dir / f"shard-{index:02d}"
    shard_dir.mkdir(parents=True, exist_ok=False)
    torch.export.save(exported, shard_dir / "source.pt2")
    (shard_dir / "source_graph.txt").write_text(
        exported.graph_module.code.rstrip() + "\n"
    )

    rd = ct.RangeDim(
        lower_bound=674,
        upper_bound=752,
        default=752,
        symbol="flow_frames",
    )
    types = []
    for name, tensor in zip(input_names, example):
        shape = list(tensor.shape)
        if index == 0 and name in {"x", "mask", "mu", "cond"}:
            shape[2] = rd
        elif index > 0 and name == "h":
            shape[1] = rd
        elif index > 0 and name == "mask":
            shape[2] = rd
        types.append(
            ct.TensorType(
                name=name,
                shape=tuple(shape),
                dtype=np.float32,
            )
        )

    converted = ct.convert(
        exported,
        source="pytorch",
        inputs=types,
        outputs=[
            ct.TensorType(name=name, dtype=np.float32)
            for name in output_names
        ],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS18,
        compute_precision=precision,
        skip_model_load=True,
    )
    package = shard_dir / "flow-shard.mlpackage"
    converted.save(str(package))

    compiled = shard_dir / "compiled"
    compiled.mkdir()
    subprocess.run(
        ["xcrun", "coremlcompiler", "compile", str(package), str(compiled)],
        check=True,
    )

    return {
        "index": index,
        "blocks": list(CUTS[index]),
        "sourceSymbolic": True,
        "rangeConstraints": {
            str(key): str(value)
            for key, value in exported.range_constraints.items()
        },
        "package": package,
        "packageSha256": sha(package),
        "operationInventory": inventory_package(package),
    }


def coreml_first_call(models, case):
    t = np.zeros((2,), dtype=np.float32)
    feed = {
        "x": case["noise"].repeat(2, 1, 1).cpu().numpy(),
        "mask": case["mask"].cpu().numpy(),
        "mu": case["mu"].cpu().numpy(),
        "t": t,
        "spks": case["spks"].cpu().numpy(),
        "cond": case["cond"].cpu().numpy(),
    }

    boundaries = []
    result = models[0].predict(feed)
    boundaries.append({"h": result["h"], "te": result["te"]})
    middle_feed = {
        "h": result["h"],
        "te": result["te"],
        "mask": feed["mask"],
    }

    for index in range(1, 5):
        result = models[index].predict(middle_feed)
        middle_feed["h"] = result["h_out"]
        boundaries.append({"h": result["h_out"]})

    result = models[5].predict(middle_feed)
    return result["velocity"], boundaries


def cosine_span(steps: int) -> np.ndarray:
    values = np.arange(steps + 1, dtype=np.float32) / np.float32(steps)
    return np.float32(1.0) - np.cos(values * np.float32(math.pi / 2.0)).astype(np.float32)


def source_rollout(full_graph, case, steps: int = 6):
    span = cosine_span(steps)
    state = case["noise"].clone()
    cfg = np.float32(0.7)

    with torch.no_grad():
        for index in range(steps):
            current = float(span[index])
            dt = float(span[index + 1] - span[index])
            t = torch.full(
                (2,),
                current,
                dtype=case["mu"].dtype,
            )
            batch_x = state.repeat(2, 1, 1)
            velocity = full_graph(
                batch_x,
                case["mask"],
                case["mu"],
                t,
                case["spks"],
                case["cond"],
            )
            guided = (
                (1.0 + float(cfg)) * velocity[0:1]
                - float(cfg) * velocity[1:2]
            )
            state = state + dt * guided

    return state


def coreml_rollout(models, case, steps: int = 6):
    span = cosine_span(steps)
    state = case["noise"].cpu().numpy().astype(np.float32, copy=True)
    mask = case["mask"].cpu().numpy()
    mu = case["mu"].cpu().numpy()
    spks = case["spks"].cpu().numpy()
    cond = case["cond"].cpu().numpy()
    cfg = np.float32(0.7)

    for index in range(steps):
        current = np.float32(span[index])
        dt = np.float32(span[index + 1] - span[index])
        batch_x = np.concatenate((state, state), axis=0)
        feed = {
            "x": batch_x,
            "mask": mask,
            "mu": mu,
            "t": np.asarray([current, current], dtype=np.float32),
            "spks": spks,
            "cond": cond,
        }
        first = models[0].predict(feed)
        middle_feed = {
            "h": first["h"],
            "te": first["te"],
            "mask": mask,
        }
        for shard_index in range(1, 5):
            value = models[shard_index].predict(middle_feed)
            middle_feed["h"] = value["h_out"]
        velocity = models[5].predict(middle_feed)["velocity"]
        guided = (
            np.float32(1.7) * velocity[0:1]
            - np.float32(0.7) * velocity[1:2]
        )
        state = state + dt * guided.astype(np.float32, copy=False)

    return state


def fixed_conditions_feed(flow_fixture):
    return {
        "tokens": flow_fixture["token"][:, :225].int().cpu().numpy(),
        "prompt_tokens": flow_fixture["prompt_token"].int().cpu().numpy(),
        "prompt_feat": flow_fixture["prompt_feat"].float().cpu().numpy(),
        "speaker": flow_fixture["embedding"].float().cpu().numpy(),
    }


def frozen_rollout(
    fixed_conditions_model,
    fixed_models,
    flow_fixture,
    noise,
    steps: int = 6,
):
    conditions = fixed_conditions_model.predict(
        fixed_conditions_feed(flow_fixture)
    )
    case = {
        "noise": noise,
        "mask": torch.ones(2, 1, 752),
        "mu": torch.from_numpy(conditions["mu"]),
        "spks": torch.from_numpy(conditions["spks"]),
        "cond": torch.from_numpy(conditions["cond"]),
    }
    return coreml_rollout(fixed_models, case, steps=steps)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--model-dir", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--fixed-asset-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument(
        "--precision",
        choices=("fp16", "fp32"),
        default="fp16",
    )
    args = parser.parse_args()

    args.output.mkdir(parents=True, exist_ok=False)
    receipt_path = args.output / "receipt.json"
    receipt: dict[str, Any] = {
        "schemaVersion": 1,
        "status": "RUNNING",
        "phase": "source",
        "sourceCommit": subprocess.check_output(
            ["git", "rev-parse", "HEAD"],
            cwd=ROOT,
            text=True,
        ).strip(),
        "pinnedUpstream": PIN,
        "modelRevision": "29e01c4e8d000f4bcd70751be16fa94bf3d85a18",
        "precision": args.precision,
        "flowSteps": 6,
        "cfgRate": 0.7,
        "tests": [],
        "packages": [],
        "productionPromotion": False,
    }

    def save():
        receipt_path.write_text(
            json.dumps(receipt, indent=2, sort_keys=True) + "\n"
        )

    save()

    try:
        upstream_head = subprocess.check_output(
            ["git", "-C", str(args.source_root), "rev-parse", "HEAD"],
            text=True,
        ).strip()
        if upstream_head != PIN:
            raise RuntimeError(f"upstream pin mismatch: {upstream_head}")

        estimator = load_estimator(args.source_root, args.model_dir)
        full_graph = load_full_graph(args.source_root, estimator)
        shards = load_shards(args.source_root, estimator)
        conditioning = SymbolicConditions(
            load_reference_flow_conditioning(args.model_dir / "flow.pt")
        ).eval()

        flow_fixture = torch.load(
            args.fixture / "flow_input.pt",
            weights_only=True,
        )["kwargs"]
        frozen_args = torch.load(
            args.fixture / "estimator_00.pt",
            weights_only=True,
        )["args"]

        cases = {
            n: natural_inputs(
                n,
                conditioning,
                flow_fixture,
                frozen_args,
            )
            for n in (186, 225)
        }

        source_examples = {}
        source_first = {}

        for n, case in cases.items():
            args0, official, sharded, boundaries = source_first_call(
                full_graph,
                shards,
                case,
            )
            metric = metrics(
                official.detach().cpu().numpy(),
                sharded.detach().cpu().numpy(),
            )
            if (
                not metric["finite"]
                or metric["maxAbsError"] > 1e-6
                or metric["relativeL2"] > 1e-7
            ):
                raise RuntimeError(
                    f"source six-shard decomposition mismatch at N={n}: {metric}"
                )
            source_first[n] = {
                "args": args0,
                "official": official,
                "sharded": sharded,
                "boundaries": boundaries,
                "metric": metric,
            }

        receipt["sourceSixShardVsFull"] = {
            str(n): source_first[n]["metric"]
            for n in (186, 225)
        }

        h225, te225 = shards[0](*source_first[225]["args"])
        source_examples[0] = source_first[225]["args"]
        for index in range(1, 6):
            source_examples[index] = (
                h225,
                te225,
                cases[225]["mask"],
            )
            if index < 5:
                h225 = shards[index](
                    h225,
                    te225,
                    cases[225]["mask"],
                )

        precision = (
            ct.precision.FLOAT16
            if args.precision == "fp16"
            else ct.precision.FLOAT32
        )

        for index, shard in enumerate(shards):
            receipt["phase"] = f"export_shard_{index}"
            save()
            package = export_package(
                shard,
                index,
                source_examples[index],
                args.output / "packages",
                precision,
            )
            receipt["packages"].append(
                {
                    key: value
                    for key, value in package.items()
                    if key != "package"
                }
            )
            save()

        models = [
            ct.models.MLModel(
                str(
                    args.output
                    / "packages"
                    / f"shard-{index:02d}"
                    / "flow-shard.mlpackage"
                ),
                compute_units=ct.ComputeUnit.CPU_ONLY,
            )
            for index in range(6)
        ]

        manifest_path, fixed_conditions_path, fixed_shard_paths = load_fixed(
            args.fixed_asset_root
        )
        receipt["fixedAssetManifestSha256"] = sha(manifest_path)
        receipt["fixedShardSha256"] = [
            sha(path) for path in fixed_shard_paths
        ]

        fixed_conditions_model = ct.models.MLModel(
            str(fixed_conditions_path),
            compute_units=ct.ComputeUnit.CPU_ONLY,
        )
        fixed_models = [
            ct.models.MLModel(
                str(path),
                compute_units=ct.ComputeUnit.CPU_ONLY,
            )
            for path in fixed_shard_paths
        ]

        for n, case in cases.items():
            receipt["phase"] = f"host_validate_N{n}"
            save()

            coreml_velocity, coreml_boundaries = coreml_first_call(
                models,
                case,
            )
            official_velocity = source_first[n]["official"].cpu().numpy()

            boundary_rows = []
            for index in range(5):
                expected = source_first[n]["boundaries"][index]["h"].cpu().numpy()
                actual = coreml_boundaries[index]["h"]
                boundary_rows.append(
                    {
                        "index": index,
                        "hVsSource": metrics(expected, actual),
                    }
                )

            first_call = metrics(
                official_velocity,
                coreml_velocity,
            )

            source_state = source_rollout(
                full_graph,
                case,
                steps=6,
            )
            coreml_state = coreml_rollout(
                models,
                case,
                steps=6,
            )

            source_mel = (
                source_state[:, :, 302:]
                .detach()
                .cpu()
                .numpy()
            )
            coreml_mel = coreml_state[:, :, 302:]

            row: dict[str, Any] = {
                "N": n,
                "G": 2 * n,
                "P": 302,
                "T": 302 + 2 * n,
                "firstCallVelocityVsOfficial": first_call,
                "boundaryMetrics": boundary_rows,
                "sixStepStateVsOfficial": metrics(
                    source_state.detach().cpu().numpy(),
                    coreml_state,
                ),
                "sixStepMelVsOfficial": metrics(
                    source_mel,
                    coreml_mel,
                ),
                "generatedMelShape": list(coreml_mel.shape),
                "finite": bool(np.isfinite(coreml_mel).all()),
            }

            if n == 225:
                frozen_state = frozen_rollout(
                    fixed_conditions_model,
                    fixed_models,
                    flow_fixture,
                    case["noise"],
                    steps=6,
                )
                frozen_mel = frozen_state[:, :, 302:]
                row["frozenSixStepMelVsOfficial"] = metrics(
                    source_mel,
                    frozen_mel,
                )
                row["dynamicSixStepMelVsFrozen"] = metrics(
                    frozen_mel,
                    coreml_mel,
                )

            receipt["tests"].append(row)
            save()

        receipt["phase"] = "complete"
        receipt["status"] = (
            "PASS_PHASE2_HOST_DYNAMIC_FLOW_EXECUTION_NUMERICS_RECORDED_NOT_PROMOTED"
            if all(row.get("finite") for row in receipt["tests"])
            else "FAIL_NONFINITE_DYNAMIC_FLOW"
        )

    except Exception as exc:
        receipt["status"] = "FAIL"
        receipt["error"] = str(exc)
        receipt["exceptionType"] = type(exc).__name__
        receipt["traceback"] = traceback.format_exc()

    finally:
        save()
        print(json.dumps(receipt, indent=2, sort_keys=True), flush=True)
        print(
            f"[COSYVOICE3-DYNAMIC-PHASE2] receipt={receipt_path}",
            flush=True,
        )

    return (
        0
        if receipt.get("status")
        == "PASS_PHASE2_HOST_DYNAMIC_FLOW_EXECUTION_NUMERICS_RECORDED_NOT_PROMOTED"
        else 1
    )


if __name__ == "__main__":
    raise SystemExit(main())


# Code purpose: prove or reject complete six-shard natural-length dynamic Flow at T674/T752 and compare the 6-step N225 result against both official PyTorch and the accepted frozen fixed225 six-shard path.
# Upstream source: CosyVoice3_NPU@878940245562bcd1dd0231d78157ba78d70b39f6 Flow/DiT and accepted fixed225 runtime assets.
# Runtime environment: macOS arm64, Python 3.11, torch 2.7, coremltools 9, Core ML CPU_ONLY.
# Generated time: 2026-10-03 America/New_York.
# Changes: new experiment-only complete dynamic Flow exporter/host validator; no HiFT, Swift shipping runtime, LLM EOS/cap, Candidate evidence, or public asset changes.
