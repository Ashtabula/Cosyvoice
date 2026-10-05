# export_enumerated_production_family.py
# Requirement: build the production-intended CosyVoice3 N=1...450 exact-shape acoustic family as four iOS18 multifunction functions. Each real EOS length remains exact; no padding, bucket substitution, mel crop, or PCM crop is allowed.
from __future__ import annotations

import argparse
import gc
import hashlib
import json
import shutil
import subprocess
import sys
import traceback
from pathlib import Path

import coremltools as ct
import numpy as np
import torch

from probe_symbolic_conditions import ROOT, PIN, SymbolicConditions, sha
from run_phase2_dynamic_flow import (
    CUTS,
    OUTPUT_NAMES,
    canonicalize_export_example as canonicalize_flow_example,
    load_estimator,
    load_full_graph,
    load_reference_flow_conditioning,
    load_shards,
    source_first_call,
    to_coreml_case,
    coreml_first_call,
)
from run_phase3_dynamic_hift import (
    DynamicHiFTBody,
    UPSAMPLE,
    canonicalize_export_example as canonicalize_hift_example,
    load_hift,
)
from run_shard0_attribution import metrics

BASE = ROOT / "ios/.work/rebuild/ios-fixed225-reference"
N_MIN = 1
N_MAX = 450
PROMPT_FRAMES = 302
FAMILIES = (
    (1, 128, "n001_128"),
    (129, 256, "n129_256"),
    (257, 384, "n257_384"),
    (385, 450, "n385_450"),
)
DEFAULT_FUNCTION = "n129_256"

EXPECTED_SHARED_PROFILE = "ios-dynamic-n1-n479-reference"
EXPECTED_SHARED_VERSION = "0.2.0-rc1"
EXPECTED_SHARED_RUNTIME_PROFILE = "ios18-dynamic-n1-n479"
EXPECTED_SHARED_PAYLOAD_TREE = "3f7b9239af32ba5644f1c607aa8a4eb0aa2651454c1b1be7db86ef811c41ab68"
EXPECTED_FLOW_PT_SHA256 = "a6fab32a7825e5b0bc855ddd948f8db9370b0a786fbc249caa4595e95b608e4b"
EXPECTED_ACOUSTIC_CONFIG_SHA256 = "f5a6b2c6f05139d0f18861a1fe506f751e787026b77c05f7e8fef9f8a4405965"


def save_json(path: Path, value) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def tree_bytes(path: Path) -> int:
    if path.is_file():
        return path.stat().st_size
    return sum(p.stat().st_size for p in path.rglob("*") if p.is_file())


def shipping_file_rows(root: Path) -> list[dict]:
    excluded = {"enumerated-production-export-receipt.json"}
    rows = []
    for path in sorted(item for item in root.rglob("*") if item.is_file()):
        if path.name in excluded or ".family-build" in path.parts:
            continue
        rows.append({
            "path": path.relative_to(root).as_posix(),
            "bytes": path.stat().st_size,
            "sha256": sha(path),
        })
    return rows


def tree_identity(rows: list[dict]) -> str:
    digest = hashlib.sha256()
    for row in sorted(rows, key=lambda item: item["path"]):
        digest.update(row["path"].encode("utf-8"))
        digest.update(b"\0")
        digest.update(str(int(row["bytes"])).encode("ascii"))
        digest.update(b"\0")
        digest.update(row["sha256"].encode("ascii"))
        digest.update(b"\n")
    return digest.hexdigest()


def validate_immutable_shared_root(root: Path) -> dict:
    manifest_path = root / "asset-manifest.json"
    if not manifest_path.is_file():
        raise RuntimeError(f"immutable shared asset-manifest.json missing: {manifest_path}")
    manifest = json.loads(manifest_path.read_text())
    expected = {
        "profile": EXPECTED_SHARED_PROFILE,
        "assetVersion": EXPECTED_SHARED_VERSION,
        "runtimeProfile": EXPECTED_SHARED_RUNTIME_PROFILE,
        "payloadTreeSha256": EXPECTED_SHARED_PAYLOAD_TREE,
    }
    for key, value in expected.items():
        if manifest.get(key) != value:
            raise RuntimeError(
                f"immutable shared root identity mismatch {key}: "
                f"{manifest.get(key)!r} != {value!r}"
            )
    rows = []
    for path in sorted(item for item in root.rglob("*") if item.is_file()):
        if path.name == "asset-manifest.json":
            continue
        rows.append({
            "path": path.relative_to(root).as_posix(),
            "bytes": path.stat().st_size,
            "sha256": sha(path),
        })
    actual_tree = tree_identity(rows)
    if actual_tree != EXPECTED_SHARED_PAYLOAD_TREE:
        raise RuntimeError(
            f"immutable shared payload tree mismatch: {actual_tree} "
            f"!= {EXPECTED_SHARED_PAYLOAD_TREE}"
        )
    if int(manifest.get("fileCount", -1)) != len(rows):
        raise RuntimeError("immutable shared payload fileCount mismatch")
    if int(manifest.get("payloadBytes", -1)) != sum(int(row["bytes"]) for row in rows):
        raise RuntimeError("immutable shared payloadBytes mismatch")
    return {
        "assetManifestSha256": sha(manifest_path),
        "profile": EXPECTED_SHARED_PROFILE,
        "version": EXPECTED_SHARED_VERSION,
        "runtimeProfile": EXPECTED_SHARED_RUNTIME_PROFILE,
        "payloadTreeSha256": actual_tree,
        "payloadBytes": sum(int(row["bytes"]) for row in rows),
        "fileCount": len(rows),
    }


def family_values(lo: int, hi: int) -> list[int]:
    values = list(range(lo, hi + 1))
    if len(values) > 128:
        raise RuntimeError(f"Core ML EnumeratedShapes family exceeds 128 shapes: {lo}...{hi}")
    return values


def enum_shape(shapes, default):
    return ct.EnumeratedShapes(shapes=[list(v) for v in shapes], default=list(default))


def compile_package(package: Path, output: Path) -> Path:
    output.mkdir(parents=True, exist_ok=False)
    subprocess.run(["xcrun", "coremlcompiler", "compile", str(package), str(output)], check=True)
    candidates = sorted(output.glob("*.mlmodelc"))
    if len(candidates) != 1:
        raise RuntimeError(f"expected one compiled model for {package}, got {candidates}")
    return candidates[0]


def merge_functions(function_packages: list[tuple[str, Path]], output: Path) -> dict:
    descriptor = ct.utils.MultiFunctionDescriptor()
    individual_bytes = 0
    for function_name, package in function_packages:
        descriptor.add_function(
            str(package),
            src_function_name="main",
            target_function_name=function_name,
        )
        individual_bytes += tree_bytes(package)
    descriptor.default_function_name = DEFAULT_FUNCTION
    ct.utils.save_multifunction(descriptor, str(output))
    merged_bytes = tree_bytes(output)
    return {
        "path": str(output),
        "sha256": sha(output),
        "individualFamilyBytes": individual_bytes,
        "mergedBytes": merged_bytes,
        "deduplicatedBytes": individual_bytes - merged_bytes,
        "mergedOverIndividualRatio": merged_bytes / individual_bytes if individual_bytes else None,
        "functions": [name for name, _ in function_packages],
        "defaultFunction": DEFAULT_FUNCTION,
    }


def convert_family(exported, inputs, outputs, precision, package: Path) -> None:
    model = ct.convert(
        exported,
        source="pytorch",
        inputs=inputs,
        outputs=[ct.TensorType(name=name, dtype=np.float32) for name in outputs],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS18,
        compute_precision=precision,
        skip_model_load=True,
    )
    model.save(str(package))


def export_conditions(conditioning, fixture, work: Path, receipt: dict) -> Path:
    example = (
        torch.zeros((1, N_MAX), dtype=torch.int32),
        fixture["prompt_token"].int().contiguous(),
        fixture["prompt_feat"].float().contiguous(),
        fixture["embedding"].float().contiguous(),
    )
    n = torch.export.Dim("speech_tokens", min=N_MIN, max=N_MAX)
    exported = torch.export.export(
        conditioning,
        example,
        dynamic_shapes=({1: n}, {}, {}, {}),
        strict=False,
    )
    if exported.dialect == "TRAINING":
        exported = exported.run_decompositions({})
    source = work / "conditions-source.pt2"
    torch.export.save(exported, source)

    family_packages = []
    for lo, hi, function_name in FAMILIES:
        values = family_values(lo, hi)
        default_n = 225 if lo <= 225 <= hi else values[0]
        inputs = [
            ct.TensorType(
                name="tokens",
                shape=enum_shape(((1, value) for value in values), (1, default_n)),
                dtype=np.int32,
            ),
            ct.TensorType(name="prompt_tokens", shape=tuple(example[1].shape), dtype=np.int32),
            ct.TensorType(name="prompt_feat", shape=tuple(example[2].shape), dtype=np.float32),
            ct.TensorType(name="speaker", shape=tuple(example[3].shape), dtype=np.float32),
        ]
        package = work / f"conditions-{function_name}.mlpackage"
        convert_family(exported, inputs, ("mu", "spks", "cond"), ct.precision.FLOAT32, package)
        family_packages.append((function_name, package))

    merged = work.parent / "conditions.mlpackage"
    receipt["conditions"] = merge_functions(family_packages, merged)
    receipt["conditions"]["sourcePt2Sha256"] = sha(source)
    return merged


def flow_case(n: int, conditioning, fixture):
    tokens = torch.zeros((1, n), dtype=torch.int32)
    with torch.no_grad():
        mu, spks, cond = conditioning(
            tokens,
            fixture["prompt_token"].int(),
            fixture["prompt_feat"].float(),
            fixture["embedding"].float(),
        )
    t = PROMPT_FRAMES + 2 * n
    return {
        "N": n,
        "G": 2 * n,
        "P": PROMPT_FRAMES,
        "T": t,
        "mu": mu,
        "spks": spks,
        "cond": cond,
        "noise": torch.zeros((1, 80, t), dtype=mu.dtype),
        "mask": torch.ones((2, 1, t), dtype=mu.dtype),
    }


def export_flow(shards, conditioning, fixture, work: Path, receipt: dict) -> list[Path]:
    case = flow_case(N_MAX, conditioning, fixture)
    batch_x = case["noise"].repeat(2, 1, 1)
    t = torch.zeros(2, dtype=case["mu"].dtype)
    current = (
        batch_x,
        case["mask"],
        case["mu"],
        t,
        case["spks"],
        case["cond"],
    )
    examples = [current]
    with torch.no_grad():
        h, te = shards[0](*current)
        for index in range(1, 6):
            current = (h.detach().contiguous(), te.detach().contiguous(), case["mask"].detach().contiguous())
            examples.append(current)
            if index < 5:
                h = shards[index](*current)

    merged_paths = []
    flow_receipts = []
    for index, (shard, example) in enumerate(zip(shards, examples)):
        example, boundary = canonicalize_flow_example(shard, index, example)
        frame = torch.export.Dim(
            f"flow_frames_{index}",
            min=PROMPT_FRAMES + 2 * N_MIN,
            max=PROMPT_FRAMES + 2 * N_MAX,
        )
        if index == 0:
            dynamic_shapes = ({2: frame}, {2: frame}, {2: frame}, {}, {}, {2: frame})
            names = ("x", "mask", "mu", "t", "spks", "cond")
        else:
            dynamic_shapes = ({1: frame}, {}, {2: frame})
            names = ("h", "te", "mask")
        exported = torch.export.export(shard, example, dynamic_shapes=dynamic_shapes, strict=False)
        if exported.dialect == "TRAINING":
            exported = exported.run_decompositions({})
        source = work / f"flow-shard-{index}-source.pt2"
        torch.export.save(exported, source)

        family_packages = []
        for lo, hi, function_name in FAMILIES:
            ns = family_values(lo, hi)
            ts = [PROMPT_FRAMES + 2 * n for n in ns]
            default_n = 225 if lo <= 225 <= hi else ns[0]
            default_t = PROMPT_FRAMES + 2 * default_n
            inputs = []
            for name, tensor in zip(names, example):
                if index == 0 and name in {"x", "mask", "mu", "cond"}:
                    shapes = []
                    for value in ts:
                        shape = list(tensor.shape)
                        shape[2] = value
                        shapes.append(shape)
                    default_shape = list(tensor.shape)
                    default_shape[2] = default_t
                    inputs.append(ct.TensorType(name=name, shape=enum_shape(shapes, default_shape), dtype=np.float32))
                elif index > 0 and name == "h":
                    shapes = []
                    for value in ts:
                        shape = list(tensor.shape)
                        shape[1] = value
                        shapes.append(shape)
                    default_shape = list(tensor.shape)
                    default_shape[1] = default_t
                    inputs.append(ct.TensorType(name=name, shape=enum_shape(shapes, default_shape), dtype=np.float32))
                elif index > 0 and name == "mask":
                    shapes = []
                    for value in ts:
                        shape = list(tensor.shape)
                        shape[2] = value
                        shapes.append(shape)
                    default_shape = list(tensor.shape)
                    default_shape[2] = default_t
                    inputs.append(ct.TensorType(name=name, shape=enum_shape(shapes, default_shape), dtype=np.float32))
                else:
                    inputs.append(ct.TensorType(name=name, shape=tuple(tensor.shape), dtype=np.float32))
            package = work / f"flow-shard-{index}-{function_name}.mlpackage"
            output_names = ("h", "te") if index == 0 else (OUTPUT_NAMES[index],)
            convert_family(exported, inputs, output_names, ct.precision.FLOAT16, package)
            family_packages.append((function_name, package))

        merged = work.parent / f"flow-shard-{index}.mlpackage"
        info = merge_functions(family_packages, merged)
        info.update(index=index, blocks=list(CUTS[index]), sourcePt2Sha256=sha(source), exportBoundaryLayout=boundary)
        flow_receipts.append(info)
        merged_paths.append(merged)

    receipt["flowShards"] = flow_receipts
    return merged_paths


def hift_example(body, n: int):
    frames = 2 * n
    samples = UPSAMPLE * frames
    mel = torch.linspace(-0.25, 0.25, steps=80 * frames, dtype=torch.float32).reshape(1, 80, frames).contiguous()
    f0 = torch.full((1, frames), 120.0, dtype=torch.float32)
    phase = torch.zeros((1, frames, 9), dtype=torch.float32)
    noise = torch.zeros((1, samples, 9), dtype=torch.float32)
    window = torch.hann_window(16, periodic=True, dtype=torch.float64)
    norm = torch.nn.functional.conv_transpose1d(
        torch.ones((1, 1, samples // 4 + 1), dtype=torch.float32),
        window.float().square()[None, None],
        stride=4,
    )[:, :, 8:-8].contiguous()
    return mel, f0, phase, noise, norm


def export_hift(body, work: Path, receipt: dict) -> Path:
    example, canonical = canonicalize_hift_example(hift_example(body, N_MAX))
    frame = torch.export.Dim("mel_frames", min=2 * N_MIN, max=2 * N_MAX)
    samples = UPSAMPLE * frame
    exported = torch.export.export(
        body,
        example,
        dynamic_shapes=({2: frame}, {1: frame}, {1: frame}, {1: samples}, {2: samples}),
        strict=False,
    )
    if exported.dialect == "TRAINING":
        exported = exported.run_decompositions({})
    source = work / "hift-source.pt2"
    torch.export.save(exported, source)

    names = ("mel", "f0", "phase", "noise", "norm")
    dynamic_axes = {"mel": 2, "f0": 1, "phase": 1, "noise": 1, "norm": 2}
    family_packages = []
    for lo, hi, function_name in FAMILIES:
        ns = family_values(lo, hi)
        default_n = 225 if lo <= 225 <= hi else ns[0]
        inputs = []
        for name, tensor in zip(names, example):
            axis = dynamic_axes[name]
            shapes = []
            for n in ns:
                shape = list(tensor.shape)
                shape[axis] = 2 * n if name in {"mel", "f0", "phase"} else 960 * n
                shapes.append(shape)
            default_shape = list(tensor.shape)
            default_shape[axis] = 2 * default_n if name in {"mel", "f0", "phase"} else 960 * default_n
            inputs.append(ct.TensorType(name=name, shape=enum_shape(shapes, default_shape), dtype=np.float32))
        package = work / f"hift-{function_name}.mlpackage"
        convert_family(exported, inputs, ("pcm",), ct.precision.FLOAT32, package)
        family_packages.append((function_name, package))

    merged = work.parent / "hift.mlpackage"
    info = merge_functions(family_packages, merged)
    info.update(sourcePt2Sha256=sha(source), exportInputCanonicalization=canonical)
    receipt["hift"] = info
    return merged


def multifunction_expected_abi(package_name: str) -> tuple[list[str], list[str]]:
    if package_name == "conditions.mlpackage":
        return sorted(("tokens", "prompt_tokens", "prompt_feat", "speaker")), sorted(("mu", "spks", "cond"))
    if package_name == "flow-shard-0.mlpackage":
        return sorted(("x", "mask", "mu", "t", "spks", "cond")), sorted(("h", "te"))
    if package_name in {f"flow-shard-{index}.mlpackage" for index in range(1, 5)}:
        return sorted(("h", "te", "mask")), ["h_out"]
    if package_name == "flow-shard-5.mlpackage":
        return sorted(("h", "te", "mask")), ["velocity"]
    if package_name == "hift.mlpackage":
        return sorted(("mel", "f0", "phase", "noise", "norm")), ["pcm"]
    raise RuntimeError(f"no expected ABI declared for multifunction package: {package_name}")


def verify_multifunction_load(packages: list[Path], receipt: dict) -> None:
    result = []
    for package in packages:
        expected_inputs, expected_outputs = multifunction_expected_abi(package.name)
        for _, _, function_name in FAMILIES:
            model = ct.models.MLModel(
                str(package),
                function_name=function_name,
                compute_units=ct.ComputeUnit.CPU_ONLY,
            )
            actual_inputs = sorted(model.input_description.keys())
            actual_outputs = sorted(model.output_description.keys())
            if actual_inputs != expected_inputs or actual_outputs != expected_outputs:
                raise RuntimeError(
                    f"multifunction ABI mismatch package={package.name} function={function_name} "
                    f"inputs={actual_inputs} expectedInputs={expected_inputs} "
                    f"outputs={actual_outputs} expectedOutputs={expected_outputs}"
                )
            result.append({
                "package": package.name,
                "function": function_name,
                "inputNames": actual_inputs,
                "outputNames": actual_outputs,
            })
            del model
            gc.collect()
    receipt["hostMultifunctionLoad"] = {
        "status": "PASS_FUNCTION_LOAD_AND_ABI",
        "functions": result,
    }


REPRESENTATIVE_NS = (1, 128, 129, 167, 225, 256, 257, 384, 385, 450)


def function_name_for_n(n: int) -> str:
    for lo, hi, name in FAMILIES:
        if lo <= n <= hi:
            return name
    raise RuntimeError(f"N outside enumerated production contract: {n}")


def validate_representative_predictions(
    *,
    conditions_package: Path,
    flow_packages: list[Path],
    hift_package: Path,
    conditioning,
    full,
    shards,
    hift_body,
    fixture,
    receipt: dict,
) -> None:
    tests = []
    grouped: dict[str, list[int]] = {}
    for n in REPRESENTATIVE_NS:
        grouped.setdefault(function_name_for_n(n), []).append(n)

    for function_name, values in grouped.items():
        conditions_model = ct.models.MLModel(
            str(conditions_package),
            function_name=function_name,
            compute_units=ct.ComputeUnit.CPU_ONLY,
        )
        flow_models = [
            ct.models.MLModel(
                str(package),
                function_name=function_name,
                compute_units=ct.ComputeUnit.CPU_ONLY,
            )
            for package in flow_packages
        ]
        hift_model = ct.models.MLModel(
            str(hift_package),
            function_name=function_name,
            compute_units=ct.ComputeUnit.CPU_ONLY,
        )

        for n in values:
            case = flow_case(n, conditioning, fixture)
            tokens = np.zeros((1, n), dtype=np.int32)
            condition_feed = {
                "tokens": tokens,
                "prompt_tokens": fixture["prompt_token"].int().cpu().numpy(),
                "prompt_feat": fixture["prompt_feat"].float().cpu().numpy(),
                "speaker": fixture["embedding"].float().cpu().numpy(),
            }
            condition_result = conditions_model.predict(condition_feed)
            condition_metrics = {
                name: metrics(
                    case[name].detach().cpu().numpy(),
                    np.asarray(condition_result[name], dtype=np.float32),
                )
                for name in ("mu", "spks", "cond")
            }
            if any(
                (not value["finite"]) or value["relativeL2"] > 1.0e-4
                for value in condition_metrics.values()
            ):
                raise RuntimeError(
                    f"enumerated Conditions parity failed N={n} function={function_name}: {condition_metrics}"
                )

            _, _, source_sharded, _ = source_first_call(full, shards, case)
            coreml_velocity, _ = coreml_first_call(flow_models, to_coreml_case(case))
            flow_metric = metrics(
                source_sharded.detach().cpu().numpy(),
                np.asarray(coreml_velocity, dtype=np.float32),
            )
            expected_t = PROMPT_FRAMES + 2 * n
            if (
                not flow_metric["finite"]
                or tuple(np.asarray(coreml_velocity).shape) != (2, 80, expected_t)
            ):
                raise RuntimeError(
                    f"enumerated Flow execution failed N={n} function={function_name}: "
                    f"shape={np.asarray(coreml_velocity).shape} metrics={flow_metric}"
                )

            hift_inputs = hift_example(hift_body, n)
            with torch.no_grad():
                source_pcm = hift_body(*hift_inputs).detach().cpu().numpy()
            hift_feed = {
                name: tensor.detach().cpu().numpy().astype(np.float32, copy=False)
                for name, tensor in zip(("mel", "f0", "phase", "noise", "norm"), hift_inputs)
            }
            coreml_pcm = np.asarray(hift_model.predict(hift_feed)["pcm"], dtype=np.float32)
            hift_metric = metrics(source_pcm, coreml_pcm)
            if (
                not hift_metric["finite"]
                or tuple(coreml_pcm.shape) != (1, 960 * n)
                or hift_metric["relativeL2"] > 0.02
            ):
                raise RuntimeError(
                    f"enumerated HiFT parity failed N={n} function={function_name}: "
                    f"shape={coreml_pcm.shape} metrics={hift_metric}"
                )

            tests.append({
                "N": n,
                "T": expected_t,
                "G": 2 * n,
                "samples": 960 * n,
                "functionName": function_name,
                "conditionsVsSource": condition_metrics,
                "flowFirstCallVsSourceSharded": flow_metric,
                "hiftSameInputVsSourceBody": hift_metric,
            })

        del conditions_model, flow_models, hift_model
        gc.collect()

    receipt["representativeExactShapeValidation"] = {
        "status": "PASS_HOST_EXECUTION",
        "Ns": list(REPRESENTATIVE_NS),
        "tests": tests,
        "conditionsRelativeL2Maximum": 1.0e-4,
        "flowPolicy": "finite exact output shape; numerical error recorded without inventing a new FP16 Flow promotion threshold",
        "hiftRelativeL2Maximum": 0.02,
    }


def validate_hift_against_immutable_dynamic(
    *,
    enumerated_hift: Path,
    shared_root: Path,
    shared_manifest: dict,
    receipt: dict,
) -> None:
    n = 225
    inputs = hift_example(None, n)
    feed = {
        name: tensor.detach().cpu().numpy().astype(np.float32, copy=False)
        for name, tensor in zip(("mel", "f0", "phase", "noise", "norm"), inputs)
    }
    enumerated = ct.models.MLModel(
        str(enumerated_hift),
        function_name="n129_256",
        compute_units=ct.ComputeUnit.CPU_ONLY,
    )
    immutable = ct.models.MLModel(
        str(shared_root / shared_manifest["hift"]),
        compute_units=ct.ComputeUnit.CPU_ONLY,
    )
    new_pcm = np.asarray(enumerated.predict(feed)["pcm"], dtype=np.float32)
    immutable_pcm = np.asarray(immutable.predict(feed)["pcm"], dtype=np.float32)
    metric = metrics(immutable_pcm, new_pcm)
    if (
        not metric["finite"]
        or tuple(new_pcm.shape) != (1, 960 * n)
        or metric["relativeL2"] > 0.02
    ):
        raise RuntimeError(
            "enumerated HiFT does not match the immutable accepted dynamic HiFT "
            f"at N225: shape={new_pcm.shape} metrics={metric}"
        )
    receipt["immutableDynamicHiFTOracle"] = {
        "status": "PASS",
        "N": n,
        "functionName": "n129_256",
        "immutablePackageSha256": sha(shared_root / shared_manifest["hift"]),
        "enumeratedPackageSha256": sha(enumerated_hift),
        "sameInputRelativeL2Maximum": 0.02,
        "metrics": metric,
    }
    del enumerated, immutable
    gc.collect()


def copy_path(source: Path, destination: Path) -> None:
    if destination.exists():
        raise RuntimeError(f"refusing to overwrite staged shared asset: {destination}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    if source.is_dir():
        shutil.copytree(source, destination)
    else:
        shutil.copy2(source, destination)


def stage_shared_assets(output: Path, shared_root: Path, shared_manifest: dict, receipt: dict) -> None:
    copied = []
    shared_paths = [
        shared_manifest["tokenizerFolder"],
        shared_manifest["textEmbedding"],
        shared_manifest["speechEmbedding"],
        shared_manifest["llmPrefill"],
        shared_manifest["llmDecode"],
        shared_manifest["f0Folder"],
    ]
    reference = shared_manifest.get("referenceEnrollment")
    if isinstance(reference, dict):
        shared_paths.extend([
            reference["speechTokenizer"],
            reference["campPlus"],
            reference["whisperMel128"],
            reference["kaldiMel80"],
            reference["matchaMel80"],
        ])
    dynamic = shared_manifest.get("dynamicAcoustic")
    if not isinstance(dynamic, dict):
        raise RuntimeError("shared manifest must be the validated schema-2 dynamic profile")
    shared_paths.extend([
        dynamic["defaultPromptTokens"],
        dynamic["defaultPromptFeat"],
        dynamic["defaultSpeaker"],
    ])
    for relative in dict.fromkeys(shared_paths):
        source = shared_root / relative
        if not source.exists():
            raise RuntimeError(f"missing shared asset: {source}")
        destination = output / relative
        copy_path(source, destination)
        copied.append({"path": relative, "bytes": tree_bytes(destination), "sha256": sha(destination)})

    source_nmax = int(dynamic["speechTokenMaximum"])
    if source_nmax < N_MAX:
        raise RuntimeError(f"shared stochastic buffers stop at N={source_nmax}, need N={N_MAX}")
    source_t = int(dynamic["promptFrameCount"]) + 2 * source_nmax
    target_t = PROMPT_FRAMES + 2 * N_MAX
    flow_source = shared_root / dynamic["flowNoiseMaximum"]
    flow = np.fromfile(flow_source, dtype=np.float32)
    if flow.size != 80 * source_t:
        raise RuntimeError(f"shared Flow noise size mismatch: {flow.size} != {80 * source_t}")
    flow = flow.reshape(1, 80, source_t)[:, :, :target_t].copy()
    flow_destination = output / "enumerated-acoustic/buffers/flow-noise-max.f32"
    flow_destination.parent.mkdir(parents=True, exist_ok=True)
    flow.tofile(flow_destination)

    source_samples = 960 * source_nmax
    target_samples = 960 * N_MAX
    hift_source = shared_root / dynamic["hiftExcitationMaximum"]
    excitation = np.fromfile(hift_source, dtype=np.float32)
    if excitation.size != source_samples * 9:
        raise RuntimeError(f"shared HiFT excitation size mismatch: {excitation.size} != {source_samples * 9}")
    excitation = excitation.reshape(1, source_samples, 9)[:, :target_samples, :].copy()
    hift_destination = output / "enumerated-acoustic/buffers/hift-excitation-max.f32"
    excitation.tofile(hift_destination)

    receipt["sharedAssets"] = {
        "sourceRoot": str(shared_root),
        "copied": copied,
        "flowNoiseMaximum": {
            "path": str(flow_destination.relative_to(output)),
            "bytes": flow_destination.stat().st_size,
            "sha256": sha(flow_destination),
            "sourceMaximumN": source_nmax,
            "targetMaximumN": N_MAX,
        },
        "hiftExcitationMaximum": {
            "path": str(hift_destination.relative_to(output)),
            "bytes": hift_destination.stat().st_size,
            "sha256": sha(hift_destination),
            "sourceMaximumN": source_nmax,
            "targetMaximumN": N_MAX,
        },
    }


def write_manifest(output: Path, shared_manifest: dict, receipt: dict) -> Path:
    manifest = dict(shared_manifest)
    manifest["schemaVersion"] = 3
    manifest["profile"] = "ios18-enumerated-n1-n450"
    manifest["flowMask"] = None
    manifest["flowNoise"] = None
    manifest["flowConditions"] = "enumerated-acoustic/conditions.mlpackage"
    manifest["flowShards"] = [f"enumerated-acoustic/flow-shard-{i}.mlpackage" for i in range(6)]
    manifest["hift"] = "enumerated-acoustic/hift.mlpackage"
    manifest["dynamicAcoustic"] = None
    manifest["enumeratedAcoustic"] = {
        "status": "CANDIDATE",
        "speechTokenMinimum": N_MIN,
        "speechTokenMaximum": N_MAX,
        "promptFrameCount": PROMPT_FRAMES,
        "logicalPrefixMaximumForFullSpeechWindow": 512 - N_MAX,
        "families": [
            {"speechTokenMinimum": lo, "speechTokenMaximum": hi, "functionName": name}
            for lo, hi, name in FAMILIES
        ],
        "defaultPromptTokens": shared_manifest["dynamicAcoustic"]["defaultPromptTokens"],
        "defaultPromptFeat": shared_manifest["dynamicAcoustic"]["defaultPromptFeat"],
        "defaultSpeaker": shared_manifest["dynamicAcoustic"]["defaultSpeaker"],
        "flowNoiseMaximum": "enumerated-acoustic/buffers/flow-noise-max.f32",
        "hiftExcitationMaximum": "enumerated-acoustic/buffers/hift-excitation-max.f32",
    }
    reference = manifest.get("referenceEnrollment")
    if isinstance(reference, dict) and reference.get("status") == "PASS_DEVICE_PARITY":
        reference = dict(reference)
        reference["flowConditionsDynamic"] = manifest["flowConditions"]
        manifest["referenceEnrollment"] = reference
    path = output / "cosyvoice3_enumerated.json"
    save_json(path, manifest)
    receipt["manifest"] = {"path": str(path), "sha256": sha(path)}
    return path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--shared-root", type=Path, required=True,
                        help="Validated immutable schema-2 dynamic asset root used as the source of unchanged tokenizer/LLM/reference/F0 assets and stochastic buffers.")
    parser.add_argument("--rebuild-root", type=Path, default=BASE,
                        help="Pinned local rebuild root containing source/, model-cache/Fun-CosyVoice3-0.5B-2512/, and fixture/. Defaults to the canonical ios/.work rebuild path.")
    parser.add_argument("--keep-intermediates", action="store_true")
    args = parser.parse_args()

    source_commit = subprocess.check_output(
        ["git", "-C", str(ROOT), "rev-parse", "HEAD"],
        text=True,
    ).strip()
    source_status = subprocess.check_output(
        ["git", "-C", str(ROOT), "status", "--porcelain"],
        text=True,
    )
    if source_status.strip():
        raise SystemExit(
            "refusing enumerated production export from a dirty source tree:\n"
            + source_status
        )

    shared_root = args.shared_root.expanduser().resolve()
    shared_identity = validate_immutable_shared_root(shared_root)
    shared_manifest_path = shared_root / "cosyvoice3_dynamic.json"
    if not shared_manifest_path.is_file():
        raise SystemExit(f"immutable shared runtime manifest missing: {shared_manifest_path}")
    shared_manifest = json.loads(shared_manifest_path.read_text())
    if shared_manifest.get("schemaVersion") != 2 or shared_manifest.get("profile") != EXPECTED_SHARED_RUNTIME_PROFILE:
        raise SystemExit("immutable shared runtime manifest identity mismatch")

    if args.output.exists():
        raise SystemExit(f"output already exists: {args.output}")
    args.output.mkdir(parents=True)
    acoustic = args.output / "enumerated-acoustic"
    acoustic.mkdir()
    work = acoustic / ".family-build"
    work.mkdir()

    receipt = {
        "schemaVersion": 1,
        "status": "RUNNING",
        "sourceCommit": source_commit,
        "pinnedUpstream": PIN,
        "profile": "ios18-enumerated-n1-n450",
        "productionPromotion": False,
        "speechTokenBounds": [N_MIN, N_MAX],
        "logicalPrefixMaximumForFullSpeechWindow": 512 - N_MAX,
        "families": [
            {"speechTokenMinimum": lo, "speechTokenMaximum": hi, "count": hi - lo + 1, "functionName": name}
            for lo, hi, name in FAMILIES
        ],
        "exactShapeCount": N_MAX,
        "padding": False,
        "crop": False,
        "flowStepsUnchanged": True,
        "sharedImmutableSource": shared_identity,
    }
    receipt_path = args.output / "enumerated-production-export-receipt.json"

    def save():
        save_json(receipt_path, receipt)

    save()
    try:
        rebuild_root = args.rebuild_root.expanduser().resolve()
        source = rebuild_root / "source"
        model = rebuild_root / "model-cache/Fun-CosyVoice3-0.5B-2512"
        fixture_root = rebuild_root / "fixture"
        flow_checkpoint = model / "flow.pt"
        hift_checkpoint = model / "hift.pt"
        acoustic_config = model / "cosyvoice3.yaml"
        flow_fixture_path = fixture_root / "flow_input.pt"
        for required in (source, model, flow_checkpoint, hift_checkpoint, acoustic_config, flow_fixture_path):
            if not required.exists():
                raise RuntimeError(f"enumerated rebuild prerequisite missing: {required}")
        upstream_head = subprocess.check_output(
            ["git", "-C", str(source), "rev-parse", "HEAD"],
            text=True,
        ).strip()
        if upstream_head != PIN:
            raise RuntimeError(f"upstream source pin mismatch: {upstream_head} != {PIN}")
        upstream_status = subprocess.check_output(
            ["git", "-C", str(source), "status", "--porcelain", "--untracked-files=no"],
            text=True,
        )
        if upstream_status.strip():
            raise RuntimeError(
                "pinned upstream tracked worktree is dirty:\n" + upstream_status
            )
        submodules = subprocess.check_output(
            ["git", "-C", str(source), "submodule", "status", "--recursive"],
            text=True,
        )
        bad_submodules = [
            line for line in submodules.splitlines()
            if line and line[0] in {"+", "-", "U"}
        ]
        if bad_submodules:
            raise RuntimeError(
                "pinned upstream submodule checkout mismatch:\n"
                + "\n".join(bad_submodules)
            )
        flow_sha = sha(flow_checkpoint)
        config_sha = sha(acoustic_config)
        if flow_sha != EXPECTED_FLOW_PT_SHA256:
            raise RuntimeError(
                f"flow checkpoint SHA mismatch: {flow_sha} != {EXPECTED_FLOW_PT_SHA256}"
            )
        if config_sha != EXPECTED_ACOUSTIC_CONFIG_SHA256:
            raise RuntimeError(
                f"acoustic config SHA mismatch: {config_sha} != {EXPECTED_ACOUSTIC_CONFIG_SHA256}"
            )
        fixture = torch.load(flow_fixture_path, weights_only=True)["kwargs"]
        receipt["rebuildInputs"] = {
            "rebuildRoot": str(rebuild_root),
            "upstreamSourceCommit": upstream_head,
            "upstreamTrackedTreeClean": True,
            "upstreamSubmoduleStatus": submodules.splitlines(),
            "flowCheckpointSha256": flow_sha,
            "hiftCheckpointSha256": sha(hift_checkpoint),
            "acousticConfigSha256": config_sha,
            "flowFixtureSha256": sha(flow_fixture_path),
        }

        receipt["phase"] = "load_source"
        save()
        torch.set_num_threads(4)
        conditioning = SymbolicConditions(load_reference_flow_conditioning(model / "flow.pt")).eval()
        estimator = load_estimator(source, model)
        full = load_full_graph(source, estimator)
        shards = load_shards(source, estimator)

        case = flow_case(225, conditioning, fixture)
        _, official, sharded, _ = source_first_call(full, shards, case)
        receipt["sourceSixShardVsFullAtN225"] = metrics(official.numpy(), sharded.numpy())
        if receipt["sourceSixShardVsFullAtN225"]["maxAbsError"] != 0.0:
            raise RuntimeError("source six-shard N225 control is not bit exact")

        receipt["phase"] = "conditions"
        save()
        conditions_package = export_conditions(conditioning, fixture, work, receipt)
        save()

        receipt["phase"] = "flow"
        save()
        flow_packages = export_flow(shards, conditioning, fixture, work, receipt)
        save()

        # Keep source Flow objects until multifunction representative execution
        # so exact-shape Core ML output can be compared against the same source math.

        receipt["phase"] = "hift"
        save()
        hift, config_receipt = load_hift(source, model, work)
        body = DynamicHiFTBody(hift).eval()
        receipt["hiftConfigReceipt"] = config_receipt
        hift_package = export_hift(body, work, receipt)
        save()

        receipt["phase"] = "compile_multifunction"
        save()
        packages = [conditions_package, *flow_packages, hift_package]
        compiled = []
        for package in packages:
            compiled_dir = work / f"compiled-{package.stem}"
            compiled_url = compile_package(package, compiled_dir)
            compiled.append({
                "package": package.name,
                "compiledBytes": tree_bytes(compiled_url),
                "compiledSha256": sha(compiled_url),
                "transientCompileValidation": True,
            })
        receipt["compiled"] = compiled
        save()

        receipt["phase"] = "host_multifunction_load"
        save()
        verify_multifunction_load(packages, receipt)
        save()

        receipt["phase"] = "representative_exact_shape_execution"
        save()
        validate_representative_predictions(
            conditions_package=conditions_package,
            flow_packages=flow_packages,
            hift_package=hift_package,
            conditioning=conditioning,
            full=full,
            shards=shards,
            hift_body=body,
            fixture=fixture,
            receipt=receipt,
        )
        save()

        receipt["phase"] = "immutable_dynamic_hift_oracle"
        save()
        validate_hift_against_immutable_dynamic(
            enumerated_hift=hift_package,
            shared_root=shared_root,
            shared_manifest=shared_manifest,
            receipt=receipt,
        )
        save()
        del full, shards, estimator, body, hift
        gc.collect()
        receipt["phase"] = "stage_shared_assets"
        save()
        stage_shared_assets(args.output, shared_root, shared_manifest, receipt)
        write_manifest(args.output, shared_manifest, receipt)
        receipt["phase"] = "validate_standalone_root"
        save()
        validator = ROOT / "ios/assets/validate_assets.py"
        subprocess.run(
            [sys.executable, str(validator), "--root", str(args.output), "--require-reference-files"],
            check=True,
        )

        receipt["assetPackageBytes"] = sum(tree_bytes(p) for p in packages)
        if not args.keep_intermediates:
            shutil.rmtree(work)
        receipt["intermediatesRetained"] = args.keep_intermediates
        payload_rows = shipping_file_rows(args.output)
        receipt["payloadBytes"] = sum(int(row["bytes"]) for row in payload_rows)
        receipt["payloadFileCount"] = len(payload_rows)
        receipt["payloadTreeSha256"] = tree_identity(payload_rows)
        receipt["standaloneRootBytes"] = tree_bytes(args.output)
        receipt["status"] = "PASS_ENUMERATED_N1_N450_EXPORT_NOT_PROMOTED"
        receipt["phase"] = "complete"
    except Exception as exc:
        receipt.update(status="FAIL", error=str(exc), traceback=traceback.format_exc())
    save()
    print(json.dumps(receipt, indent=2, sort_keys=True), flush=True)
    return 0 if receipt["status"].startswith("PASS_") else 1


if __name__ == "__main__":
    raise SystemExit(main())

# Code purpose: export the final production architecture for natural-EOS CosyVoice3 acoustic inference: exact N=1...450 shapes split only because Core ML limits one EnumeratedShapes list to 128 shapes, then weight-deduplicated into multifunction mlprogram packages.
# Upstream source: pinned CosyVoice3 acoustic math and the already validated N1...479 RangeDim exporter; no model weights, Flow scheduler math, CFG, F0, HiFT body, seed/noise prefix, EOS, or public API semantics are changed.
# Runtime environment: macOS arm64, Python 3.11, torch 2.7, coremltools 9, Xcode 27/coremlcompiler; target iOS 18+.
# Generated time: 2026-10-05 America/New_York.
# Changed lines: new production exporter; four exact-shape function families 1-128/129-256/257-384/385-450, schema-3 manifest emission, multifunction weight dedup accounting, compile/load gates, and no-padding/no-crop invariants.

# Changes 2026-10-05: assemble a standalone production asset root from the immutable schema-2 shared assets instead of requiring the frozen fixed225 profile. Unchanged tokenizer/LLM/reference/F0/default-conditioning files are copied byte-for-byte; N479 stochastic buffers are deterministically narrowed to the N450 production maximum with channel-correct slicing.

# Changes 2026-10-05: compiled mlmodelc artifacts are transient validation products under .family-build and are removed from the shipping root; the exporter now runs the standalone schema-3 asset validator before declaring PASS.

# Changes 2026-10-05: fix production exporter Flow shard-0 ABI: the first shard has two outputs (h, te), while shards 1...5 have one output. Swift CI cannot catch this conversion-only mismatch; exporter now preserves the validated six-shard ABI exactly.

# Changes 2026-10-05: final standaloneRootBytes is measured only after transient .family-build removal (unless --keep-intermediates is explicit), so production size evidence no longer counts conversion/compiled validation artifacts that are not shipped.

# Changes 2026-10-05: multifunction host gate now validates complete selected-function input/output ABI for Conditions, all six Flow shards, and HiFT across all four families. Conversion succeeds only if shard0 exposes both h and te and every other stage matches the Swift runtime contract.

# Changes 2026-10-05: schema-3 manifest explicitly clears legacy fixed-shape flowMask/flowNoise fields; exact variable runtime owns its mask at request shape and uses the schema-3 maximum stochastic buffer contract instead of stale fixed225 paths.

# Changes 2026-10-05: production exporter now executes representative exact shapes N=1/128/129/167/225/256/257/384/385/450 through every selected multifunction family on host CPU. Conditions must retain <=1e-4 relativeL2, Flow must be finite with exact velocity shape while recording FP16 error, and same-input HiFT must retain the existing <=0.02 relativeL2 gate.

# Changes 2026-10-05: representative exact-shape validation now supplies the full canonical Flow case ABI (N/G/P/T). This prevents to_coreml_case/source helpers from failing at asset-build time even though Swift CI is green.

# Changes 2026-10-05: final schema-3 build records deterministic per-file payload identity (path/bytes/SHA256 -> payloadTreeSha256) after transient cleanup. The mutable export receipt is excluded from its own tree hash, eliminating circular identity while binding every shipping model/shared asset byte.

# Changes 2026-10-05: production exporter exposes --rebuild-root instead of silently trusting one hidden .work path, fail-closes unless pinned upstream source HEAD equals 8789402..., and records exact flow checkpoint/fixture SHA256 in the export receipt before model conversion.

# Changes 2026-10-05: Python exporter now independently refuses any dirty Git worktree before creating the output root and reuses that exact clean HEAD in the receipt. Direct exporter invocation has the same provenance gate as the shell wrapper.

# Changes 2026-10-05: production schema-3 export now requires the exact frozen schema-2 private RC source (ios-dynamic-n1-n479-reference/0.2.0-rc1, runtime ios18-dynamic-n1-n479-candidate, payload tree 3f7b...). It recomputes every source file hash/tree/byte count before conversion and records the immutable source manifest/tree in the new receipt.

# Changes 2026-10-05: correct frozen shared runtimeProfile gate to ios18-dynamic-n1-n479, matching the canonical dynamic publish script constant; the previous review-only -candidate suffix was invalid.

# Changes 2026-10-05: Flow/Conditions export now hard-requires the accepted flow.pt SHA256 a6fab32a..., and HiFT construction hard-requires the accepted cosyvoice3.yaml SHA256 f5a6b2c6.... The exact local hift.pt SHA is recorded for independent output binding.

# Changes 2026-10-05: N225 enumerated HiFT now runs an independent same-input Core ML oracle against the exact immutable accepted schema-2 dynamic HiFT package. relativeL2 must remain <=0.02, so an incorrect local hift.pt cannot pass merely by agreeing with its own PyTorch source body.

# Changes 2026-10-05: pinned upstream validation now rejects tracked source modifications and any recursive submodule checkout marked +, -, or U. HiFT/Matcha code therefore comes from the exact parent-commit submodule state rather than merely sharing the same top-level HEAD.
