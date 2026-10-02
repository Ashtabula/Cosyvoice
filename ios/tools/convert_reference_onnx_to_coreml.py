#!/usr/bin/env python3
#@title convert_reference_onnx_to_coreml.py
# Requirement: convert the selected single-reference speech tokenizer and CAMPPlus ONNX graphs into fixed-profile Core ML packages.
# Requirement: preserve input/output names used by frontend.py and emit a machine-readable receipt; conversion is NOT promotion.
import argparse
import hashlib
import json
from pathlib import Path

import coremltools as ct
import numpy as np
import onnx
import torch
from onnx2torch import convert
from onnx2torch.node_converters import registry as onnx2torch_registry


def install_onnx2torch_schema_aliases():
    """Register ONNX schema-version aliases whose operator semantics are unchanged."""
    aliases = [
        ("", "GreaterOrEqual", 12, 16),
        ("", "LessOrEqual", 12, 16),
    ]
    installed = []
    for domain, operation_type, source_version, target_version in aliases:
        source = onnx2torch_registry.OperationDescription(
            domain=domain,
            operation_type=operation_type,
            version=source_version,
        )
        target = onnx2torch_registry.OperationDescription(
            domain=domain,
            operation_type=operation_type,
            version=target_version,
        )
        converter = onnx2torch_registry._CONVERTER_REGISTRY.get(source)
        if converter is None:
            raise RuntimeError(
                f"onnx2torch missing expected source converter {source}"
            )
        if target not in onnx2torch_registry._CONVERTER_REGISTRY:
            onnx2torch_registry._CONVERTER_REGISTRY[target] = converter
            installed.append({
                "operation": operation_type,
                "sourceVersion": source_version,
                "targetVersion": target_version,
            })
    return installed


def unsupported_onnx2torch_nodes(model):
    opsets = {entry.domain: entry.version for entry in model.opset_import}
    unsupported = {}
    for node in model.graph.node:
        domain = node.domain or ""
        version = opsets.get(domain, 1)
        try:
            onnx2torch_registry.get_converter(
                operation_type=node.op_type,
                version=version,
                domain=domain,
            )
        except NotImplementedError as error:
            key = (domain, node.op_type, version, str(error))
            unsupported[key] = unsupported.get(key, 0) + 1
    return [
        {
            "domain": domain,
            "operation": operation,
            "modelOpset": version,
            "count": count,
            "error": error,
        }
        for (domain, operation, version, error), count in sorted(
            unsupported.items(),
            key=lambda item: (item[0][0], item[0][1], item[0][2]),
        )
    ]


def assert_onnx2torch_supported(name, model):
    unsupported = unsupported_onnx2torch_nodes(model)
    if unsupported:
        print(json.dumps({
            "status": "UNSUPPORTED_ONNX2TORCH_OPERATORS",
            "model": name,
            "unsupported": unsupported,
        }, indent=2))
        raise RuntimeError(
            f"{name} contains {len(unsupported)} unsupported ONNX operator/version groups"
        )


class SpeechTokenizer(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, feats, feats_length):
        value = self.model(feats, feats_length)
        if isinstance(value, (tuple, list)):
            value = value[0]
        return value


class CampPlus(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, input):
        value = self.model(input)
        if isinstance(value, (tuple, list)):
            value = value[0]
        return value


def package_hash(path: Path):
    h = hashlib.sha256()
    total = 0
    for file in sorted(p for p in path.rglob("*") if p.is_file()):
        payload = file.read_bytes()
        h.update(str(file.relative_to(path)).encode())
        h.update(payload)
        total += len(payload)
    return h.hexdigest(), total


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--speech-tokenizer", type=Path, required=True)
    p.add_argument("--campplus", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    args = p.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)

    speech_onnx = onnx.load(str(args.speech_tokenizer))
    camp_onnx = onnx.load(str(args.campplus))

    aliases = install_onnx2torch_schema_aliases()
    if aliases:
        print(json.dumps({
            "status": "ONNX2TORCH_SCHEMA_ALIASES_INSTALLED",
            "aliases": aliases,
        }, indent=2))

    assert_onnx2torch_supported("speech_tokenizer_v3.onnx", speech_onnx)
    assert_onnx2torch_supported("campplus.onnx", camp_onnx)

    speech_torch = SpeechTokenizer(convert(speech_onnx).eval()).eval()
    camp_torch = CampPlus(convert(camp_onnx).eval()).eval()

    speech_example = (
        torch.zeros(1, 128, 605, dtype=torch.float32),
        torch.tensor([605], dtype=torch.int32),
    )
    camp_example = torch.zeros(1, 604, 80, dtype=torch.float32)

    with torch.inference_mode():
        speech_trace = torch.jit.trace(speech_torch, speech_example, check_trace=False)
        camp_trace = torch.jit.trace(camp_torch, (camp_example,), check_trace=False)

    speech_model = ct.convert(
        speech_trace,
        inputs=[
            ct.TensorType(name="feats", shape=speech_example[0].shape, dtype=np.float32),
            ct.TensorType(name="feats_length", shape=speech_example[1].shape, dtype=np.int32),
        ],
        outputs=[ct.TensorType(name="indices")],
        minimum_deployment_target=ct.target.iOS18,
        compute_precision=ct.precision.FLOAT32,
        compute_units=ct.ComputeUnit.CPU_ONLY,
        convert_to="mlprogram",
    )
    camp_model = ct.convert(
        camp_trace,
        inputs=[ct.TensorType(name="input", shape=camp_example.shape, dtype=np.float32)],
        outputs=[ct.TensorType(name="output")],
        minimum_deployment_target=ct.target.iOS18,
        compute_precision=ct.precision.FLOAT32,
        compute_units=ct.ComputeUnit.CPU_ONLY,
        convert_to="mlprogram",
    )

    speech_path = out / "speech-tokenizer-fixed605.mlpackage"
    camp_path = out / "campplus-fixed604.mlpackage"
    speech_model.save(str(speech_path))
    camp_model.save(str(camp_path))
    speech_hash, speech_bytes = package_hash(speech_path)
    camp_hash, camp_bytes = package_hash(camp_path)

    receipt = {
        "status": "CONVERTED_NOT_PARITY_VALIDATED",
        "profile": "fixed225-reference605-604",
        "speechTokenizer": {
            "path": str(speech_path),
            "input": {"feats": [1, 128, 605], "feats_length": [1]},
            "output": "indices",
            "sha256": speech_hash,
            "bytes": speech_bytes,
        },
        "campPlus": {
            "path": str(camp_path),
            "input": {"input": [1, 604, 80]},
            "output": "output",
            "sha256": camp_hash,
            "bytes": camp_bytes,
        },
        "promotion": "requires upstream ONNX numerical parity and physical-iPhone parity before referenceEnrollment.status may become PASS_DEVICE_PARITY",
    }
    (out / "reference_coreml_conversion.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt, indent=2))


if __name__ == "__main__":
    main()

# Code purpose: produce fixed-profile Core ML candidates for the two learned reference-enrollment graphs.
# Compatibility note: onnx2torch registers GreaterOrEqual/LessOrEqual only through schema v12 even though opset16 preserves their value semantics; v16 aliases are installed before conversion and all remaining unsupported operator/version groups are reported in one preflight pass.
# Upstream source assets: speech_tokenizer_v3.onnx and campplus.onnx from Fun-CosyVoice3-0.5B-2512 revision29e01c4e.
# Runtime: conversion host; requires coremltools, onnx, onnx2torch, torch.
# Generated: 2026-10-02 America/New_York.
