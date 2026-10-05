# export_enumerated_production_family.py
# Requirement: build the production-intended CosyVoice3 N=1...450 exact-shape acoustic family as four iOS18 multifunction functions. Each real EOS length remains exact; no padding, bucket substitution, mel crop, or PCM crop is allowed.
from __future__ import annotations

import argparse
import gc
import json
import shutil
import subprocess
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


def save_json(path: Path, value) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def tree_bytes(path: Path) -> int:
    if path.is_file():
        return path.stat().st_size
    return sum(p.stat().st_size for p in path.rglob("*") if p.is_file())


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
            convert_family(exported, inputs, (OUTPUT_NAMES[index],), ct.precision.FLOAT16, package)
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


def verify_multifunction_load(packages: list[Path], receipt: dict) -> None:
    result = []
    for package in packages:
        for _, _, function_name in FAMILIES:
            model = ct.models.MLModel(
                str(package),
                function_name=function_name,
                compute_units=ct.ComputeUnit.CPU_ONLY,
            )
            result.append({
                "package": package.name,
                "function": function_name,
                "inputNames": sorted(model.input_description.keys()),
            })
            del model
            gc.collect()
    receipt["hostMultifunctionLoad"] = {"status": "PASS", "functions": result}


def write_manifest(output: Path, shared_manifest: dict, receipt: dict) -> Path:
    manifest = dict(shared_manifest)
    manifest["schemaVersion"] = 3
    manifest["profile"] = "ios18-enumerated-n1-n450"
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
        "defaultPromptTokens": "dynamic-acoustic/buffers/default-prompt-tokens.i32",
        "defaultPromptFeat": "dynamic-acoustic/buffers/default-prompt-feat.f32",
        "defaultSpeaker": "dynamic-acoustic/buffers/default-speaker.f32",
        "flowNoiseMaximum": "dynamic-acoustic/buffers/flow-noise-max.f32",
        "hiftExcitationMaximum": "dynamic-acoustic/buffers/hift-excitation-max.f32",
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
    parser.add_argument("--shared-manifest", type=Path, required=True,
                        help="Existing immutable dynamic manifest used only for shared tokenizer/LLM/reference/buffer paths.")
    parser.add_argument("--keep-intermediates", action="store_true")
    args = parser.parse_args()

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
        "sourceCommit": subprocess.check_output(["git", "-C", str(ROOT), "rev-parse", "HEAD"], text=True).strip(),
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
    }
    receipt_path = args.output / "enumerated-production-export-receipt.json"

    def save():
        save_json(receipt_path, receipt)

    save()
    try:
        source = BASE / "source"
        model = BASE / "model-cache/Fun-CosyVoice3-0.5B-2512"
        fixture_root = BASE / "fixture"
        fixture = torch.load(fixture_root / "flow_input.pt", weights_only=True)["kwargs"]

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

        del full, shards, estimator
        gc.collect()

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
            compiled_dir = acoustic / f"compiled-{package.stem}"
            compiled_url = compile_package(package, compiled_dir)
            compiled.append({
                "package": package.name,
                "compiled": str(compiled_url),
                "compiledBytes": tree_bytes(compiled_url),
                "compiledSha256": sha(compiled_url),
            })
        receipt["compiled"] = compiled
        save()

        receipt["phase"] = "host_multifunction_load"
        save()
        verify_multifunction_load(packages, receipt)
        save()

        shared_manifest = json.loads(args.shared_manifest.read_text())
        write_manifest(args.output, shared_manifest, receipt)

        receipt["assetPackageBytes"] = sum(tree_bytes(p) for p in packages)
        receipt["status"] = "PASS_ENUMERATED_N1_N450_EXPORT_NOT_PROMOTED"
        receipt["phase"] = "complete"
        if not args.keep_intermediates:
            shutil.rmtree(work)
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
