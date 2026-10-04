# run_phase3_dynamic_hift.py
# Requirement: prove one genuine symbolic HiFT body package accepts G372 and G450 without padding/buckets, while preserving the accepted host-phase/F0/body math and fixed450 baseline.
from __future__ import annotations

import argparse
import copy
import gc
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
import torch.nn.functional as F
from torch import nn

from probe_symbolic_conditions import PIN, ROOT, extract, sha
from run_shard0_attribution import metrics

sys.path.insert(0, str(ROOT / "ios/validation"))
from prepare_acoustic_rebuild_config import derive as derive_acoustic_config


MODEL_REVISION = "29e01c4e8d000f4bcd70751be16fa94bf3d85a18"
FRAMES = (372, 450)
UPSAMPLE = 480


class DynamicHiFTBody(nn.Module):
    def __init__(self, hift):
        super().__init__()
        self.m = copy.deepcopy(hift).float().eval()
        n = torch.arange(16, dtype=torch.float64)
        k = torch.arange(9, dtype=torch.float64)[:, None]
        window = torch.hann_window(16, periodic=True, dtype=torch.float64)
        angles = 2 * torch.pi * k * n / 16
        self.register_buffer(
            "stft_basis",
            torch.cat(
                (
                    torch.cos(angles) * window,
                    -torch.sin(angles) * window,
                ),
                dim=0,
            ).float()[:, None, :],
        )
        scale = torch.tensor(
            [1] + [2] * 7 + [1],
            dtype=torch.float64,
        )[:, None] / 16
        self.register_buffer(
            "inverse_basis",
            torch.cat(
                (
                    torch.cos(angles) * scale * window,
                    -torch.sin(angles) * scale * window,
                ),
                dim=0,
            ).float()[:, None, :],
        )

    def forward(self, mel, f0, phase, noise, norm):
        m = self.m
        phase_samples = F.interpolate(
            (phase * UPSAMPLE).transpose(1, 2),
            scale_factor=UPSAMPLE,
            mode="nearest",
        ).transpose(1, 2)
        uv = (
            (f0 > 10)
            .to(dtype=mel.dtype)
            .repeat_interleave(UPSAMPLE, dim=1)[:, :, None]
        )
        sine = (
            torch.sin(phase_samples) * 0.1 * uv
            + (uv * 0.003 + (1 - uv) * 0.1 / 3) * noise
        )
        source = m.m_source.l_tanh(
            m.m_source.l_linear(sine)
        ).transpose(1, 2)
        stft = F.conv1d(
            F.pad(source, (8, 8), mode="reflect"),
            self.stft_basis,
            stride=4,
        )
        x = m.conv_pre(mel)
        for index in range(m.num_upsamples):
            x = m.ups[index](F.leaky_relu(x, m.lrelu_slope))
            if index == m.num_upsamples - 1:
                x = m.reflection_pad(x)
            x = x + m.source_resblocks[index](
                m.source_downs[index](stft)
            )
            x = sum(
                m.resblocks[index * m.num_kernels + kernel](x)
                for kernel in range(m.num_kernels)
            ) / m.num_kernels
        x = m.conv_post(F.leaky_relu(x))
        magnitude = torch.exp(x[:, :9]).clamp(max=100)
        phase_logits = torch.sin(x[:, 9:])
        spectrum = torch.cat(
            (
                magnitude * torch.cos(phase_logits),
                magnitude * torch.sin(phase_logits),
            ),
            dim=1,
        )
        pcm = F.conv_transpose1d(
            spectrum,
            self.inverse_basis,
            stride=4,
        )[:, :, 8:-8] / norm
        return pcm.clamp(
            -m.audio_limit,
            m.audio_limit,
        ).squeeze(1)


def load_hift(source_root: Path, model_dir: Path, work: Path):
    sys.path[:0] = [
        str(source_root.resolve()),
        str((source_root / "third_party/Matcha-TTS").resolve()),
    ]
    config = work / "cosyvoice3.acoustic.yaml"
    config_receipt = derive_acoustic_config(model_dir, config)

    from hyperpyyaml import load_hyperpyyaml

    with config.open() as handle:
        values = load_hyperpyyaml(
            handle,
            overrides={
                "qwen_pretrain_path": str(
                    model_dir / "CosyVoice-BlankEN"
                )
            },
        )
    hift = values["hift"].eval()
    weights = torch.load(
        model_dir / "hift.pt",
        weights_only=True,
        map_location="cpu",
    )
    hift.load_state_dict(
        {
            key.replace("generator.", ""): value
            for key, value in weights.items()
        },
        strict=True,
    )
    del values
    gc.collect()
    return hift, config_receipt


def load_fixed_oracle_class(source_root: Path):
    namespace = {
        "copy": copy,
        "np": np,
        "torch": torch,
        "F": F,
        "nn": nn,
    }
    extract(
        source_root,
        "iOS/tools/export_pipeline_acoustics.py",
        ["HiFTPortable"],
        namespace,
    )
    return namespace["HiFTPortable"]


def mel_fixture(fixture_root: Path) -> torch.Tensor:
    record = torch.load(
        fixture_root / "hift_input.pt",
        weights_only=True,
    )
    kwargs = record.get("kwargs") or {}
    if "speech_feat" in kwargs:
        mel = kwargs["speech_feat"]
    else:
        args = record.get("args") or ()
        if not args:
            raise RuntimeError("hift_input.pt has no mel tensor")
        mel = args[0]
    if tuple(mel.shape) != (1, 80, 450):
        raise RuntimeError(
            f"unexpected fixed HiFT fixture shape: {tuple(mel.shape)}"
        )
    return mel.float().contiguous()


def host_phase(f0: torch.Tensor) -> torch.Tensor:
    values = f0.detach().cpu().numpy().astype(
        np.float32,
        copy=False,
    )
    harmonics = np.arange(
        1,
        10,
        dtype=np.float32,
    )[None, None, :]
    radians = np.remainder(
        values[:, :, None]
        * harmonics
        / np.float32(24000),
        np.float32(1),
    )
    phase = (
        np.cumsum(
            radians.astype(np.float64),
            axis=1,
        ).astype(np.float32)
        * np.float32(2 * np.pi)
    )
    return torch.from_numpy(phase)


def frame_buffers(hift, frames: int):
    samples = frames * UPSAMPLE
    noise = (
        hift.m_source.l_sin_gen.sine_waves[
            :, :samples
        ]
        .detach()
        .float()
        .contiguous()
    )
    if noise.shape[1] != samples:
        raise RuntimeError(
            f"official HiFT noise buffer shorter than {samples}: {tuple(noise.shape)}"
        )

    window = torch.hann_window(
        16,
        periodic=True,
        dtype=torch.float64,
    )
    norm = F.conv_transpose1d(
        torch.ones(
            1,
            1,
            samples // 4 + 1,
            dtype=torch.float32,
        ),
        window.float().square()[None, None],
        stride=4,
    )[:, :, 8:-8].contiguous()

    if tuple(norm.shape) != (1, 1, samples):
        raise RuntimeError(
            f"HiFT norm shape mismatch: {tuple(norm.shape)}"
        )
    return noise, norm


def fixed_asset_hift(asset_root: Path):
    manifest_path = asset_root / "cosyvoice3_fixed225.json"
    manifest = json.loads(manifest_path.read_text())
    relative = manifest.get("hift")
    if not relative:
        raise RuntimeError("fixed asset manifest has no HiFT package")
    return manifest_path, asset_root / relative


def source_cases(
    hift,
    fixed_oracle_class,
    dynamic_body,
    fixture_mel,
):
    cases = {}
    for frames in FRAMES:
        mel = fixture_mel[:, :, :frames].contiguous()
        fixed = fixed_oracle_class(
            hift,
            frames,
        ).eval()
        # Use no_grad, not inference_mode: these tensors become torch.export
        # examples later, and AOTAutograd cannot save inference tensors.
        with torch.no_grad():
            f0 = fixed.m.f0_predictor(mel)
            phase = host_phase(f0)
            noise, norm = frame_buffers(hift, frames)
            fixed_pcm = fixed(
                mel,
                f0,
                phase,
            )
            dynamic_pcm = dynamic_body(
                mel,
                f0,
                phase,
                noise,
                norm,
            )
            upstream_pcm, _ = hift.inference(
                mel,
                finalize=True,
            )

        exact = metrics(
            fixed_pcm.detach().cpu().numpy(),
            dynamic_pcm.detach().cpu().numpy(),
        )
        if (
            not exact["finite"]
            or exact["maxAbsError"] != 0.0
            or exact["relativeL2"] != 0.0
        ):
            raise RuntimeError(
                f"external-buffer DynamicHiFTBody changed source math at G={frames}: {exact}"
            )

        cases[frames] = {
            "mel": mel,
            "f0": f0.float().contiguous(),
            "phase": phase.float().contiguous(),
            "noise": noise,
            "norm": norm,
            "sourcePCM": dynamic_pcm.detach().cpu().numpy().astype(
                np.float32,
                copy=True,
            ),
            "fixedSourcePCM": fixed_pcm.detach().cpu().numpy().astype(
                np.float32,
                copy=True,
            ),
            "upstreamPCM": upstream_pcm.detach().cpu().numpy().astype(
                np.float32,
                copy=True,
            ),
            "sourceDynamicVsFixed": exact,
            "sourceShippingPathVsUpstream": metrics(
                upstream_pcm.detach().cpu().numpy(),
                dynamic_pcm.detach().cpu().numpy(),
            ),
        }
    return cases


def canonicalize_export_example(example):
    canonical = []
    records = []
    for index, tensor in enumerate(example):
        before = tensor.detach()
        array = np.array(
            before.cpu().numpy(),
            copy=True,
        )
        after = torch.from_numpy(array).to(
            dtype=before.dtype,
        ).contiguous()

        exact = bool(torch.equal(before.cpu(), after))
        is_inference = bool(
            getattr(after, "is_inference", lambda: False)()
        )
        record = {
            "index": index,
            "shape": list(before.shape),
            "dtype": str(before.dtype),
            "beforeStride": list(before.stride()),
            "afterStride": list(after.stride()),
            "beforeInferenceTensor": bool(
                getattr(before, "is_inference", lambda: False)()
            ),
            "afterInferenceTensor": is_inference,
            "valuesExact": exact,
        }
        records.append(record)

        if not exact:
            raise RuntimeError(
                f"export input canonicalization changed values at position {index}"
            )
        if is_inference:
            raise RuntimeError(
                f"export input {index} is still an inference tensor after canonicalization"
            )

        canonical.append(after)

    return tuple(canonical), records


def export_dynamic_body(
    body,
    example,
    output: Path,
    receipt,
    save,
    frames=FRAMES,
):
    example, export_input_records = canonicalize_export_example(
        example
    )

    frame = torch.export.Dim(
        "mel_frames",
        min=min(frames),
        max=max(frames),
    )
    samples = UPSAMPLE * frame
    dynamic_shapes = (
        {2: frame},
        {1: frame},
        {1: frame},
        {1: samples},
        {2: samples},
    )

    exported = torch.export.export(
        body,
        example,
        dynamic_shapes=dynamic_shapes,
        strict=False,
    )
    if exported.dialect == "TRAINING":
        exported = exported.run_decompositions({})

    placeholders = {
        node.name: node
        for node in exported.graph.nodes
        if node.op == "placeholder"
    }
    # Persist actual EXIR USER_INPUT contracts before any converter can fail.
    input_records = []
    for spec in exported.graph_signature.input_specs:
        if spec.kind.name != "USER_INPUT":
            continue
        name = spec.arg.name
        value = placeholders[name].meta["val"]
        def dimension(value):
            return str(value) if isinstance(value, torch.SymInt) else int(value)
        input_records.append({
            "name": name,
            "inputSpec": str(spec),
            "shape": [dimension(d) for d in value.shape],
            "stride": [dimension(d) for d in value.stride()],
            "dtype": str(value.dtype),
            "dimOrder": list(value.dim_order()),
        })
    receipt["exportedUserInputs"] = input_records
    receipt["rangeConstraints"] = {
        str(key): str(value) for key, value in exported.range_constraints.items()
    }
    (output / "exported_user_inputs.json").write_text(
        json.dumps(input_records, indent=2) + "\n"
    )
    save()
    names = ("mel", "f0", "phase", "noise", "norm")
    if tuple(row["name"] for row in input_records) != names:
        raise RuntimeError(f"Unexpected HiFT USER_INPUT order: {input_records}")
    if input_records[2]["shape"][2] != input_records[3]["shape"][2]:
        raise RuntimeError("Phase and official noise harmonic dimensions disagree")

    mel_symbolic = isinstance(
        placeholders["mel"].meta["val"].shape[2],
        torch.SymInt,
    )
    noise_symbolic = isinstance(
        placeholders["noise"].meta["val"].shape[1],
        torch.SymInt,
    )
    if not mel_symbolic or not noise_symbolic:
        raise RuntimeError(
            "HiFT ExportedProgram did not retain symbolic frame/sample dimensions"
        )

    source_path = output / "source.pt2"
    torch.export.save(exported, source_path)
    (output / "source_graph.txt").write_text(
        exported.graph_module.code.rstrip() + "\n"
    )

    frame_rd = ct.RangeDim(
        lower_bound=min(frames),
        upper_bound=max(frames),
        default=max(frames),
        symbol="mel_frames",
    )
    sample_rd = ct.RangeDim(
        lower_bound=min(frames) * UPSAMPLE,
        upper_bound=max(frames) * UPSAMPLE,
        default=max(frames) * UPSAMPLE,
        symbol="pcm_samples",
    )

    symbolic_axes = {"mel": (2, frame_rd), "f0": (1, frame_rd),
                     "phase": (1, frame_rd), "noise": (1, sample_rd),
                     "norm": (2, sample_rd)}
    coreml_inputs = []
    contracts = []
    for row, tensor in zip(input_records, example):
        axis, range_dim = symbolic_axes[row["name"]]
        shape = list(row["shape"])
        for index, size in enumerate(shape):
            if index != axis and (not isinstance(size, int) or size != tensor.shape[index]):
                raise RuntimeError(f"Static EXIR/example dimension mismatch: {row}")
        shape[axis] = range_dim
        coreml_inputs.append(ct.TensorType(name=row["name"], shape=tuple(shape), dtype=np.float32))
        contracts.append({"name": row["name"], "shape": [str(d) for d in shape],
                          "symbolicAxis": axis, "exampleShape": list(tensor.shape)})
    receipt["coreMLInputContracts"] = contracts
    receipt["phase"] = "coreml_conversion"
    save()

    model = ct.convert(
        exported,
        source="pytorch",
        inputs=coreml_inputs,
        outputs=[
            ct.TensorType(
                name="pcm",
                dtype=np.float32,
            )
        ],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS18,
        compute_precision=ct.precision.FLOAT32,
        skip_model_load=True,
    )
    package = output / "hift-dynamic-body-fp32.mlpackage"
    model.save(str(package))

    receipt["phase"] = "coreml_compile"
    save()
    compiled = output / "compiled"
    compiled.mkdir()
    subprocess.run(
        [
            "xcrun",
            "coremlcompiler",
            "compile",
            str(package),
            str(compiled),
        ],
        check=True,
    )

    return {
        "package": package,
        "exportInputCanonicalization": export_input_records,
        "packageSha256": sha(package),
        "sourcePt2Sha256": sha(source_path),
        "melFramesSymbolic": mel_symbolic,
        "sampleCountSymbolic": noise_symbolic,
        "rangeConstraints": {
            str(key): str(value)
            for key, value in exported.range_constraints.items()
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--source-root",
        type=Path,
        required=True,
    )
    parser.add_argument(
        "--model-dir",
        type=Path,
        required=True,
    )
    parser.add_argument(
        "--fixture",
        type=Path,
        required=True,
    )
    parser.add_argument(
        "--fixed-asset-root",
        type=Path,
        required=True,
    )
    parser.add_argument(
        "--output",
        type=Path,
        required=True,
    )
    args = parser.parse_args()

    args.output.mkdir(
        parents=True,
        exist_ok=False,
    )
    receipt_path = args.output / "receipt.json"
    receipt: dict[str, Any] = {
        "schemaVersion": 1,
        "status": "RUNNING",
        "phase": "load",
        "sourceCommit": subprocess.check_output(
            ["git", "rev-parse", "HEAD"],
            cwd=ROOT,
            text=True,
        ).strip(),
        "pinnedUpstream": PIN,
        "modelRevision": MODEL_REVISION,
        "frames": list(FRAMES),
        "sampleRate": 24000,
        "samplesPerMelFrame": UPSAMPLE,
        "precision": "FLOAT32 HiFT body; existing dynamic CPU FP64 F0 remains separate",
        "tests": [],
        "productionPromotion": False,
    }

    def save():
        receipt_path.write_text(
            json.dumps(
                receipt,
                indent=2,
                sort_keys=True,
            )
            + "\n"
        )

    save()

    try:
        head = subprocess.check_output(
            [
                "git",
                "-C",
                str(args.source_root),
                "rev-parse",
                "HEAD",
            ],
            text=True,
        ).strip()
        if head != PIN:
            raise RuntimeError(
                f"upstream source pin mismatch: {head}"
            )

        hift, config_receipt = load_hift(
            args.source_root,
            args.model_dir,
            args.output,
        )
        receipt["acousticConfig"] = config_receipt

        fixed_oracle_class = load_fixed_oracle_class(
            args.source_root
        )
        dynamic_body = DynamicHiFTBody(
            hift
        ).eval()
        fixture_mel = mel_fixture(
            args.fixture
        )

        receipt["phase"] = "source_parity"
        save()

        cases = source_cases(
            hift,
            fixed_oracle_class,
            dynamic_body,
            fixture_mel,
        )

        receipt["sourceTests"] = {
            str(frames): {
                "sourceDynamicVsFixed": cases[frames][
                    "sourceDynamicVsFixed"
                ],
                "sourceShippingPathVsUpstream": cases[
                    frames
                ]["sourceShippingPathVsUpstream"],
                "pcmShape": list(
                    cases[frames]["sourcePCM"].shape
                ),
            }
            for frames in FRAMES
        }

        example_case = cases[max(FRAMES)]
        example = (
            example_case["mel"],
            example_case["f0"],
            example_case["phase"],
            example_case["noise"],
            example_case["norm"],
        )

        canonical_example, canonical_records = canonicalize_export_example(
            example
        )
        receipt["exportInputCanonicalization"] = canonical_records
        receipt["exportInputsAllNormalTensors"] = all(
            not row["afterInferenceTensor"]
            and row["valuesExact"]
            for row in canonical_records
        )
        receipt["phase"] = "export"
        save()

        export = export_dynamic_body(
            dynamic_body,
            canonical_example,
            args.output,
            receipt,
            save,
        )
        receipt["dynamicPackage"] = {
            key: value
            for key, value in export.items()
            if key != "package"
        }
        save()

        del dynamic_body
        del hift
        gc.collect()

        receipt["phase"] = "coreml_host"
        save()

        dynamic_model = ct.models.MLModel(
            str(export["package"]),
            compute_units=ct.ComputeUnit.CPU_ONLY,
        )

        manifest_path, fixed_hift_path = fixed_asset_hift(
            args.fixed_asset_root
        )
        receipt["fixedAssetManifestSha256"] = sha(
            manifest_path
        )
        receipt["fixedHiFTSha256"] = sha(
            fixed_hift_path
        )
        fixed_model = ct.models.MLModel(
            str(fixed_hift_path),
            compute_units=ct.ComputeUnit.CPU_ONLY,
        )

        for frames in FRAMES:
            case = cases[frames]
            feed = {
                "mel": case["mel"].cpu().numpy(),
                "f0": case["f0"].cpu().numpy(),
                "phase": case["phase"].cpu().numpy(),
                "noise": case["noise"].cpu().numpy(),
                "norm": case["norm"].cpu().numpy(),
            }
            prediction = dynamic_model.predict(
                feed
            )["pcm"]

            row: dict[str, Any] = {
                "G": frames,
                "expectedSamples": frames * UPSAMPLE,
                "pcmShape": list(
                    np.asarray(prediction).shape
                ),
                "finite": bool(
                    np.isfinite(prediction).all()
                ),
                "dynamicCoreMLVsSourceBody": metrics(
                    case["sourcePCM"],
                    prediction,
                ),
                "dynamicCoreMLShippingPathVsUpstream": metrics(
                    case["upstreamPCM"],
                    prediction,
                ),
            }

            if int(np.asarray(prediction).size) != frames * UPSAMPLE:
                raise RuntimeError(
                    f"dynamic HiFT PCM sample count mismatch at G={frames}: "
                    f"{np.asarray(prediction).size} != {frames * UPSAMPLE}"
                )

            if frames == 450:
                fixed_prediction = fixed_model.predict(
                    {
                        "mel": feed["mel"],
                        "f0": feed["f0"],
                        "phase": feed["phase"],
                    }
                )["pcm"]
                row["dynamicCoreMLVsFrozenCoreML"] = metrics(
                    fixed_prediction,
                    prediction,
                )
                row["frozenCoreMLVsSourceBody"] = metrics(
                    case["sourcePCM"],
                    fixed_prediction,
                )

            receipt["tests"].append(
                row
            )
            save()

        accepted = all(
            row["finite"]
            and row["dynamicCoreMLVsSourceBody"][
                "relativeL2"
            ]
            <= 0.02
            for row in receipt["tests"]
        )

        receipt["hostBodyAcceptanceThreshold"] = {
            "relativeL2Max": 0.02,
            "source": "existing shipping HiFT host gate",
        }
        receipt["dynamicHiFTBodyHostPass"] = accepted
        receipt["phase"] = "complete"
        receipt["status"] = (
            "PASS_PHASE3_HOST_DYNAMIC_HIFT_BODY_NOT_PROMOTED"
            if accepted
            else "FAIL_PHASE3_HOST_DYNAMIC_HIFT_NUMERICS"
        )

    except Exception as exc:
        receipt["status"] = "FAIL"
        receipt["error"] = str(exc)
        receipt["exceptionType"] = type(exc).__name__
        receipt["traceback"] = traceback.format_exc()

    finally:
        save()
        print(
            json.dumps(
                receipt,
                indent=2,
                sort_keys=True,
            ),
            flush=True,
        )
        print(
            f"[COSYVOICE3-DYNAMIC-PHASE3] receipt={receipt_path}",
            flush=True,
        )

    return (
        0
        if receipt.get("status")
        == "PASS_PHASE3_HOST_DYNAMIC_HIFT_BODY_NOT_PROMOTED"
        else 1
    )


if __name__ == "__main__":
    raise SystemExit(main())


# Code purpose: prove one serialized true-dynamic HiFT body accepts 372/450 mel frames and emits 178560/216000 PCM samples without padding or bucket selection.
# Upstream source: CosyVoice3_NPU@878940245562bcd1dd0231d78157ba78d70b39f6 export_pipeline_acoustics.HiFTPortable and official CausalHiFTGenerator checkpoint.
# Runtime environment: macOS arm64, Python3.11, torch2.7, coremltools9, Core ML CPU_ONLY host validation.
# Generated time: 2026-10-03 America/New_York.
# Changes: experiment-only externalization of frame-dependent official noise-prefix and iSTFT normalization tensors; source parity must be bit-exact before Core ML conversion; no shipping runtime/assets/Candidate changes.
# Changes 2026-10-04: generate source-parity intermediates under torch.no_grad instead of torch.inference_mode, then rebuild every torch.export example input as a normal CPU tensor with exact-value/stride/inference-state receipts before AOTAutograd export.

# 2026-10-04 America/New_York: export_dynamic_body derives static input dimensions
# from EXIR USER_INPUT placeholders and persists shape/stride/dtype/dim_order before
# conversion; noise preserves the official harmonic channel dimension (9).

# 2026-10-04: optional explicit frames bounds permit re-export of the same math
# for actual early-EOS lengths; default Phase3 G372..450 remains unchanged.
