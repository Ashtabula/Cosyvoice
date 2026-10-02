#@title export_dynamic_flow_conditions.py
# Requirement: export generic per-reference Flow conditioning. No prompt token, prompt mel, or speaker embedding may be frozen as a model buffer.
import argparse
import json
import sys
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
import torch.nn.functional as F

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT), str(ROOT / "third_party/Matcha-TTS")]

class DynamicConditions(torch.nn.Module):
    def __init__(self, flow):
        super().__init__()
        self.embedding = flow.input_embedding
        self.lookahead = flow.pre_lookahead_layer
        self.affine = flow.spk_embed_affine_layer

    def forward(self, tokens, prompt_tokens, prompt_feat, speaker):
        h = self.lookahead(self.embedding(torch.cat((prompt_tokens.long(), tokens.long()), dim=1)))
        h = h.repeat_interleave(2, dim=1).transpose(1, 2)
        speaker = self.affine(F.normalize(speaker, dim=1))
        cond = F.pad(prompt_feat.transpose(1, 2), (0, 450))
        return torch.cat((h, h * 0), dim=0), torch.cat((speaker, speaker * 0), dim=0), torch.cat((cond, cond * 0), dim=0)

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--model-dir", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--prompt-token-count", type=int, default=151)
    p.add_argument("--prompt-frame-count", type=int, default=302)
    args = p.parse_args()

    from hyperpyyaml import load_hyperpyyaml
    with (args.model_dir / "cosyvoice3.yaml").open() as f:
        cfg = load_hyperpyyaml(f, overrides={"qwen_pretrain_path": str(args.model_dir / "CosyVoice-BlankEN")})
    flow = cfg["flow"].eval()
    flow.load_state_dict(torch.load(args.model_dir / "flow.pt", weights_only=True, map_location="cpu"), strict=True)
    module = DynamicConditions(flow).eval()

    examples = (
        torch.zeros(1, 225, dtype=torch.int32),
        torch.zeros(1, args.prompt_token_count, dtype=torch.int32),
        torch.zeros(1, args.prompt_frame_count, 80, dtype=torch.float32),
        torch.zeros(1, 192, dtype=torch.float32),
    )
    traced = torch.jit.trace(module, examples, check_trace=False)
    model = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="tokens", shape=examples[0].shape, dtype=np.int32),
            ct.TensorType(name="prompt_tokens", shape=examples[1].shape, dtype=np.int32),
            ct.TensorType(name="prompt_feat", shape=examples[2].shape, dtype=np.float32),
            ct.TensorType(name="speaker", shape=examples[3].shape, dtype=np.float32),
        ],
        outputs=[ct.TensorType(name="mu"), ct.TensorType(name="spks"), ct.TensorType(name="cond")],
        minimum_deployment_target=ct.target.iOS18,
        compute_precision=ct.precision.FLOAT32,
        compute_units=ct.ComputeUnit.CPU_ONLY,
        convert_to="mlprogram",
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    model.save(str(args.output))
    print(json.dumps({
        "status": "EXPORTED_NOT_DEVICE_VALIDATED",
        "scope": "generic per-reference Flow conditioning",
        "output": str(args.output),
        "inputs": ["tokens", "prompt_tokens", "prompt_feat", "speaker"],
        "prompt_token_count": args.prompt_token_count,
        "prompt_frame_count": args.prompt_frame_count,
    }, indent=2))

if __name__ == "__main__":
    main()

# Code purpose: remove the benchmark-only baked reference from flow-conditions.
# Upstream: export_pipeline_acoustics.py Conditions at CosyVoice3_NPU@8789402.
# Runtime: conversion host only; generated package requires parity and device validation before promotion.
# Generated: 2026-10-02 America/New_York.
