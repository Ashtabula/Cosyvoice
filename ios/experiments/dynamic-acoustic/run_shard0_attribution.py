# run_shard0_attribution.py
# Requirement: build an identical-input N225 conversion matrix across frozen, JIT-static, ExportedProgram-static and true symbolic ExportedProgram shard0 paths without changing Flow math or release assets.
from __future__ import annotations
import argparse
import json
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

from coreml_op_inventory import diff_inventories, inventory_package
from probe_symbolic_conditions import PIN, ROOT, SymbolicConditions, extract, sha

sys.path.insert(0, str(ROOT / "ios/tools"))
from reference_flow_conditions import load_reference_flow_conditioning


def metrics(expected: Any, actual: Any) -> dict[str, Any]:
    a = np.asarray(expected, dtype=np.float64)
    b = np.asarray(actual, dtype=np.float64)
    if a.shape != b.shape:
        raise RuntimeError(f"shape mismatch {a.shape} != {b.shape}")
    diff = a - b
    norm = float(np.linalg.norm(a))
    denom = float(np.linalg.norm(a) * np.linalg.norm(b))
    return {
        "shape": list(b.shape),
        "finite": bool(np.isfinite(a).all() and np.isfinite(b).all()),
        "maxAbsError": float(np.max(np.abs(diff))) if diff.size else 0.0,
        "meanAbsError": float(np.mean(np.abs(diff))) if diff.size else 0.0,
        "rmse": float(np.sqrt(np.mean(diff * diff))) if diff.size else 0.0,
        "relativeL2": float(np.linalg.norm(diff) / norm) if norm else float(np.linalg.norm(diff)),
        "cosineSimilarity": float(np.clip(np.sum(a * b) / denom, -1.0, 1.0))
        if denom
        else float(np.array_equal(a, b)),
    }


def load_estimator(source_root: Path, model_dir: Path):
    sys.path.insert(0, str(source_root.resolve()))
    from cosyvoice.flow.DiT.dit import DiT

    config = yaml.load((model_dir / "cosyvoice3.yaml").read_text(), Loader=yaml.BaseLoader)["flow"]["decoder"][
        "estimator"
    ]
    keys = ("dim", "depth", "heads", "dim_head", "ff_mult", "mel_dim", "mu_dim", "spk_dim", "out_channels")
    estimator = DiT(
        **{key: int(config[key]) for key in keys},
        static_chunk_size=50,
        num_decoding_left_chunks=-1,
    ).eval()
    weights = torch.load(model_dir / "flow.pt", weights_only=True, map_location="cpu", mmap=True)
    prefix = "decoder.estimator."
    estimator.load_state_dict(
        {key[len(prefix) :]: value for key, value in weights.items() if key.startswith(prefix)},
        strict=True,
    )
    return estimator


def fixed_paths(asset_root: Path) -> tuple[Path, Path]:
    manifest_path = asset_root / "cosyvoice3_fixed225.json"
    manifest = json.loads(manifest_path.read_text())
    shards = manifest.get("flowShards") or []
    if len(shards) != 6:
        raise RuntimeError("fixed asset manifest does not declare six Flow shards")
    return manifest_path, asset_root / shards[0]


def make_types(sample, dynamic: bool):
    names = ("x", "mask", "mu", "t", "spks", "cond")
    if dynamic:
        frame = ct.RangeDim(lower_bound=674, upper_bound=752, default=752, symbol="flow_frames")
        result = []
        for name, tensor in zip(names, sample):
            shape = list(tensor.shape)
            if name in {"x", "mask", "mu", "cond"}:
                shape[2] = frame
            result.append(ct.TensorType(name=name, shape=tuple(shape), dtype=np.float32))
        return result
    return [
        ct.TensorType(name=name, shape=tuple(tensor.shape), dtype=np.float32)
        for name, tensor in zip(names, sample)
    ]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--model-dir", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--fixed-asset-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    receipt_path = args.output / "receipt.json"
    receipt: dict[str, Any] = {
        "schemaVersion": 1,
        "status": "RUNNING",
        "phase": "source",
        "sourceCommit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "pinnedUpstream": PIN,
        "modelRevision": "29e01c4e8d000f4bcd70751be16fa94bf3d85a18",
        "environment": {
            "torch": torch.__version__,
            "coremltools": ct.__version__,
            "numpy": np.__version__,
        },
        "variants": {},
        "pairwise": {},
        "acceptance": "UNRESOLVED_BY_DESIGN",
    }

    def save():
        receipt_path.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")

    save()
    try:
        upstream_head = subprocess.check_output(
            ["git", "-C", str(args.source_root), "rev-parse", "HEAD"], text=True
        ).strip()
        if upstream_head != PIN:
            raise RuntimeError(f"upstream pin mismatch: {upstream_head}")
        locked = subprocess.check_output(
            ["git", "-C", str(args.source_root), "show", f"{PIN}:iOS/tools/export_flow_fp16_shards.py"]
        )
        exporter_path = args.source_root / "iOS/tools/export_flow_fp16_shards.py"
        if locked != exporter_path.read_bytes():
            raise RuntimeError("pinned FirstShard exporter blob changed")

        estimator = load_estimator(args.source_root, args.model_dir)
        namespace = {"nn": nn}
        extract(args.source_root, "iOS/tools/export_flow_fp16_shards.py", ["FirstShard"], namespace)
        shard = namespace["FirstShard"](estimator, 0, 4).eval()
        conditioning = SymbolicConditions(load_reference_flow_conditioning(args.model_dir / "flow.pt")).eval()
        flow_fixture = torch.load(args.fixture / "flow_input.pt", weights_only=True)["kwargs"]
        frozen_args = torch.load(args.fixture / "estimator_00.pt", weights_only=True)["args"]

        with torch.no_grad():
            mu, spks, cond = conditioning(
                flow_fixture["token"][:, :225].int(),
                flow_fixture["prompt_token"].int(),
                flow_fixture["prompt_feat"].float(),
                flow_fixture["embedding"].float(),
            )

        sample = (
            frozen_args[0][:, :, :752].contiguous(),
            torch.ones(2, 1, 752),
            mu,
            torch.zeros(2),
            spks,
            cond,
        )
        names = ("x", "mask", "mu", "t", "spks", "cond")
        outputs = ("h", "te")

        fixture_dir = args.output / "fixture" / "N225"
        fixture_dir.mkdir(parents=True)
        input_hashes = {}
        for name, tensor in zip(names, sample):
            path = fixture_dir / f"{name}.bin"
            tensor.detach().cpu().numpy().tofile(path)
            input_hashes[name] = sha(path)

        receipt["inputSha256"] = input_hashes
        receipt["inputShapes"] = {name: list(tensor.shape) for name, tensor in zip(names, sample)}
        receipt["flowPtSha256"] = sha(args.model_dir / "flow.pt")

        manifest_path, frozen_shard0 = fixed_paths(args.fixed_asset_root)
        receipt["fixedAssetManifestSha256"] = sha(manifest_path)
        receipt["frozenShard0Sha256"] = sha(frozen_shard0)

        observed: dict[str, torch.Tensor] = {}
        hooks = [
            estimator.transformer_blocks[3].register_forward_hook(
                lambda module, inputs, output: observed.update(h=output.detach().clone())
            ),
            estimator.time_embed.register_forward_hook(
                lambda module, inputs, output: observed.update(te=output.detach().clone())
            ),
        ]
        with torch.no_grad():
            estimator(*sample, streaming=False)
        official = {"h": observed["h"].cpu().numpy(), "te": observed["te"].cpu().numpy()}
        for hook in hooks:
            hook.remove()

        for name, value in official.items():
            path = fixture_dir / f"official-{name}.bin"
            value.astype(np.float32).tofile(path)

        receipt["officialOutputSha256"] = {
            name: sha(fixture_dir / f"official-{name}.bin") for name in outputs
        }

        frozen_model = ct.models.MLModel(str(frozen_shard0), compute_units=ct.ComputeUnit.CPU_ONLY)
        feed = {name: tensor.cpu().numpy() for name, tensor in zip(names, sample)}
        frozen_prediction = frozen_model.predict(feed)
        receipt["frozenCoreMLVsOfficial"] = {
            name: metrics(official[name], frozen_prediction[name]) for name in outputs
        }

        frozen_inventory = inventory_package(frozen_shard0)
        receipt["frozenOpInventory"] = frozen_inventory

        torch.set_num_threads(4)
        variant_specs = [
            ("jit_static_fp16", "jit", False, ct.precision.FLOAT16),
            ("jit_static_fp32", "jit", False, ct.precision.FLOAT32),
            ("export_static_fp16", "export", False, ct.precision.FLOAT16),
            ("export_static_fp32", "export", False, ct.precision.FLOAT32),
            ("export_symbolic_fp16", "export", True, ct.precision.FLOAT16),
            ("export_symbolic_fp32", "export", True, ct.precision.FLOAT32),
        ]

        predictions: dict[str, dict[str, np.ndarray]] = {
            "frozen": {name: frozen_prediction[name] for name in outputs}
        }
        inventories: dict[str, dict[str, Any]] = {"frozen": frozen_inventory}

        for variant_name, frontend, dynamic, precision in variant_specs:
            row: dict[str, Any] = {
                "frontend": frontend,
                "dynamic": dynamic,
                "precision": "FLOAT16" if precision == ct.precision.FLOAT16 else "FLOAT32",
                "status": "RUNNING",
                "phase": "graph",
            }
            receipt["variants"][variant_name] = row
            save()

            variant_dir = args.output / "variants" / variant_name
            variant_dir.mkdir(parents=True, exist_ok=False)

            try:
                if frontend == "jit":
                    with torch.inference_mode():
                        graph = torch.jit.trace(shard, sample, check_trace=False)
                        graph_output = graph(*sample)
                    (variant_dir / "source_graph.txt").write_text(
                        str(graph.inlined_graph).rstrip() + "\n"
                    )
                    source_graph = graph
                    row["sourceGraphSymbolic"] = False
                else:
                    if dynamic:
                        frame = torch.export.Dim("flow_frames", min=674, max=752)
                        dynamic_shapes = ({2: frame}, {2: frame}, {2: frame}, {}, {}, {2: frame})
                    else:
                        dynamic_shapes = None

                    exported = torch.export.export(
                        shard,
                        sample,
                        dynamic_shapes=dynamic_shapes,
                        strict=False,
                    )
                    if exported.dialect == "TRAINING":
                        exported = exported.run_decompositions({})

                    graph_output = exported.module()(*sample)
                    (variant_dir / "source_graph.txt").write_text(
                        exported.graph_module.code.rstrip() + "\n"
                    )
                    torch.export.save(exported, variant_dir / "source.pt2")
                    source_graph = exported
                    x_node = next(
                        node for node in exported.graph.nodes if node.op == "placeholder" and node.name == "x"
                    )
                    row["sourceGraphSymbolic"] = isinstance(
                        x_node.meta["val"].shape[2], torch.SymInt
                    )
                    row["rangeConstraints"] = {
                        str(key): str(value) for key, value in exported.range_constraints.items()
                    }

                row["sourceGraphVsOfficial"] = {
                    name: metrics(official[name], value.detach().cpu().numpy())
                    for name, value in zip(outputs, graph_output)
                }

                row["phase"] = "conversion"
                save()

                convert_kwargs = dict(
                    inputs=make_types(sample, dynamic),
                    outputs=[ct.TensorType(name=name, dtype=np.float32) for name in outputs],
                    convert_to="mlprogram",
                    minimum_deployment_target=ct.target.iOS18,
                    compute_precision=precision,
                    skip_model_load=True,
                )
                if frontend == "export":
                    convert_kwargs["source"] = "pytorch"

                converted = ct.convert(source_graph, **convert_kwargs)
                package = variant_dir / "shard0.mlpackage"
                converted.save(str(package))
                row["packageSha256"] = sha(package)

                row["phase"] = "inventory"
                inventory = inventory_package(package)
                inventories[variant_name] = inventory
                row["opInventory"] = inventory

                row["phase"] = "compile"
                save()
                compile_dir = variant_dir / "compiled"
                compile_dir.mkdir()
                subprocess.run(
                    ["xcrun", "coremlcompiler", "compile", str(package), str(compile_dir)],
                    check=True,
                )
                row["compilation"] = "PASS"

                row["phase"] = "load"
                save()
                model = ct.models.MLModel(str(package), compute_units=ct.ComputeUnit.CPU_ONLY)
                row["loading"] = "PASS"

                row["phase"] = "predict"
                save()
                prediction = model.predict(feed)
                predictions[variant_name] = {name: prediction[name] for name in outputs}
                row["coremlVsOfficial"] = {
                    name: metrics(official[name], prediction[name]) for name in outputs
                }
                row["coremlVsFrozen"] = {
                    name: metrics(frozen_prediction[name], prediction[name]) for name in outputs
                }

                row["status"] = "EXECUTED_NUMERICS_RECORDED_NOT_ACCEPTED"
                row["phase"] = "complete"

            except Exception as exc:
                row["status"] = "FAIL"
                row["error"] = str(exc)
                row["exceptionType"] = type(exc).__name__
                row["traceback"] = traceback.format_exc()

            save()

        pairs = [
            ("export_static_fp16", "export_symbolic_fp16"),
            ("export_static_fp32", "export_symbolic_fp32"),
            ("jit_static_fp16", "export_static_fp16"),
            ("jit_static_fp16", "export_symbolic_fp16"),
            ("jit_static_fp32", "export_static_fp32"),
            ("jit_static_fp32", "export_symbolic_fp32"),
            ("export_symbolic_fp16", "export_symbolic_fp32"),
            ("export_static_fp16", "export_static_fp32"),
        ]

        for left, right in pairs:
            key = f"{left}__vs__{right}"
            if left in predictions and right in predictions:
                receipt["pairwise"][key] = {
                    name: metrics(predictions[left][name], predictions[right][name])
                    for name in outputs
                }
                receipt["pairwise"][key]["opInventoryDiff"] = diff_inventories(
                    inventories.get(left, {}),
                    inventories.get(right, {}),
                )
            else:
                receipt["pairwise"][key] = {"status": "NOT_AVAILABLE"}

        successful = [
            name
            for name, row in receipt["variants"].items()
            if row.get("status") == "EXECUTED_NUMERICS_RECORDED_NOT_ACCEPTED"
        ]
        receipt["successfulVariants"] = successful
        receipt["phase"] = "complete"
        receipt["status"] = (
            "PASS_MATRIX_COMPLETE_NUMERICAL_ACCEPTANCE_UNRESOLVED"
            if len(successful) == len(variant_specs)
            else "PARTIAL_MATRIX_WITH_FAILURES"
        )

    except Exception as exc:
        receipt["status"] = "FAIL"
        receipt["error"] = str(exc)
        receipt["exceptionType"] = type(exc).__name__
        receipt["traceback"] = traceback.format_exc()

    finally:
        save()
        print(json.dumps(receipt, indent=2, sort_keys=True), flush=True)
        print(f"[COSYVOICE3-DYNAMIC-ATTRIBUTION] receipt={receipt_path}", flush=True)

    return (
        0
        if receipt.get("status") == "PASS_MATRIX_COMPLETE_NUMERICAL_ACCEPTANCE_UNRESOLVED"
        else 1
    )


if __name__ == "__main__":
    raise SystemExit(main())


# Code purpose: identify whether shard0 drift comes from export frontend, symbolic shape or precision before any dynamic shards1-5 work.
# Upstream source: CosyVoice3_NPU@878940245562bcd1dd0231d78157ba78d70b39f6 FirstShard/DiT and accepted fixed225 asset shard0.
# Runtime environment: isolated macOS Python 3.11, torch 2.7, coremltools 9, Xcode/coremlcompiler.
# Generated time: 2026-10-03 America/New_York.
# Changes: new experiment-only N225 six-route attribution matrix; no shipping runtime or model math changes.
