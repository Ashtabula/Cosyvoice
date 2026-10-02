#!/usr/bin/env python3
# reference_flow_conditions.py
# Requirement: reconstruct only the CosyVoice3 Flow conditioning subgraph needed by the iOS custom-reference path, directly from flow.pt.
from __future__ import annotations

from pathlib import Path
from typing import Dict

import torch
import torch.nn.functional as F


EXPECTED_KEYS = {
    "input_embedding.weight",
    "pre_lookahead_layer.conv1.weight",
    "pre_lookahead_layer.conv1.bias",
    "pre_lookahead_layer.conv2.weight",
    "pre_lookahead_layer.conv2.bias",
    "spk_embed_affine_layer.weight",
    "spk_embed_affine_layer.bias",
}


class PreLookaheadLayerReplica(torch.nn.Module):
    """Exact fixed-parameter replica of upstream PreLookaheadLayer."""

    def __init__(self, in_channels: int = 80, channels: int = 1024, pre_lookahead_len: int = 3):
        super().__init__()
        self.in_channels = in_channels
        self.channels = channels
        self.pre_lookahead_len = pre_lookahead_len
        self.conv1 = torch.nn.Conv1d(
            in_channels,
            channels,
            kernel_size=pre_lookahead_len + 1,
            stride=1,
            padding=0,
        )
        self.conv2 = torch.nn.Conv1d(
            channels,
            in_channels,
            kernel_size=3,
            stride=1,
            padding=0,
        )

    def forward(self, inputs: torch.Tensor) -> torch.Tensor:
        outputs = inputs.transpose(1, 2).contiguous()
        outputs = F.pad(outputs, (0, self.pre_lookahead_len), mode="constant", value=0.0)
        outputs = F.leaky_relu(self.conv1(outputs))
        outputs = F.pad(
            outputs,
            (self.conv2.kernel_size[0] - 1, 0),
            mode="constant",
            value=0.0,
        )
        outputs = self.conv2(outputs)
        outputs = outputs.transpose(1, 2).contiguous()
        return outputs + inputs


class ReferenceFlowConditioning(torch.nn.Module):
    """Minimal upstream-equivalent conditioning graph used by the iOS reference lane."""

    def __init__(self):
        super().__init__()
        self.input_embedding = torch.nn.Embedding(6561, 80)
        self.pre_lookahead_layer = PreLookaheadLayerReplica(
            in_channels=80,
            channels=1024,
            pre_lookahead_len=3,
        )
        self.spk_embed_affine_layer = torch.nn.Linear(192, 80)

    def forward(self, tokens, prompt_tokens, prompt_feat, speaker):
        combined = torch.cat((prompt_tokens.long(), tokens.long()), dim=1)
        h = self.input_embedding(combined)
        h = self.pre_lookahead_layer(h)
        h = h.repeat_interleave(2, dim=1).transpose(1, 2)

        spks = self.spk_embed_affine_layer(F.normalize(speaker, dim=1))
        cond = F.pad(prompt_feat.transpose(1, 2), (0, 450))

        return (
            torch.cat((h, h * 0), dim=0),
            torch.cat((spks, spks * 0), dim=0),
            torch.cat((cond, cond * 0), dim=0),
        )


def extract_conditioning_state(flow_state: Dict[str, torch.Tensor]) -> Dict[str, torch.Tensor]:
    keys = set(flow_state)
    missing = sorted(EXPECTED_KEYS - keys)
    if missing:
        raise RuntimeError(f"flow.pt is missing conditioning weights: {missing}")

    extracted = {key: flow_state[key] for key in sorted(EXPECTED_KEYS)}
    unexpected_shapes = {}

    expected_shapes = {
        "input_embedding.weight": (6561, 80),
        "pre_lookahead_layer.conv1.weight": (1024, 80, 4),
        "pre_lookahead_layer.conv1.bias": (1024,),
        "pre_lookahead_layer.conv2.weight": (80, 1024, 3),
        "pre_lookahead_layer.conv2.bias": (80,),
        "spk_embed_affine_layer.weight": (80, 192),
        "spk_embed_affine_layer.bias": (80,),
    }
    for key, shape in expected_shapes.items():
        actual = tuple(extracted[key].shape)
        if actual != shape:
            unexpected_shapes[key] = {"actual": actual, "expected": shape}
    if unexpected_shapes:
        raise RuntimeError(f"conditioning weight shape mismatch: {unexpected_shapes}")

    return extracted


def load_reference_flow_conditioning(flow_pt: Path) -> ReferenceFlowConditioning:
    state = torch.load(flow_pt, weights_only=True, map_location="cpu")
    if not isinstance(state, dict):
        raise RuntimeError(f"flow.pt did not contain a state dict: {flow_pt}")

    module = ReferenceFlowConditioning().eval()
    extracted = extract_conditioning_state(state)
    module.load_state_dict(extracted, strict=True)
    return module


# Code purpose: dependency-minimal exact reconstruction of the upstream Flow conditioning subgraph.
# Upstream source: CausalMaskedDiffWithDiT + PreLookaheadLayer at CosyVoice3_NPU@878940245562bcd1dd0231d78157ba78d70b39f6.
# Runtime: conversion/parity host only; does not import the LLM, HiFT, tokenizer, dataset, or full HyperPyYAML graph.
# Generated: 2026-10-02 America/New_York.
