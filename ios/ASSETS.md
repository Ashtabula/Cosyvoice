# CosyVoice3 asset audit

Execution: local macOS workspace, 2026-09-29. Exact checkpoint revision: `29e01c4e8d000f4bcd70751be16fa94bf3d85a18`. All 20 files downloaded and size checked; all LFS payload SHA-256 values verified. Full machine-readable filenames, byte sizes, hashes, roles and intended representations are in `validation/provenance/checkpoint-lock.json` and `asset-audit.json`.

The repository contains 9,747,516,745 bytes. Selected clone-only inference weights are `llm.pt`, `flow.pt`, `hift.pt`, `campplus.onnx`, and `speech_tokenizer_v3.onnx`: 4,434,743,215 bytes as files. Add 4,187,822 bytes of selected architecture/tokenizer metadata.

Unique storage payload for the selected weights is 4,432,411,100 bytes (approximately 4.128 GiB), counting aliased PyTorch storage once and ONNX initializer bytes. This is upstream weight accounting; it is not measured ios shipping size. The theoretical payload after FP16 conversion of LLM/flow/HiFT while retaining original CPU enrollment graphs is 2,714,040,126 bytes (approximately 2.528 GiB). Conversion packaging, graph splitting, compiler overhead and numerical/quality acceptance remain unmeasured. No quantization is validated.

`llm.model.lm_head.weight` shares storage with Qwen text embeddings. Do not subtract it again from the measured unique payload. The speech logits use `llm_decoder`, while upstream's Qwen wrapper unnecessarily also computes text vocabulary logits; eliminating that compute is a future parity-gated optimization, not another removable weight copy.

`CosyVoice-BlankEN/model.safetensors` is 988,097,824 bytes. All its keys and shapes are covered by the strict `llm.pt` load. The unchanged upstream constructor needs it to instantiate Qwen, but a shipping runtime loading the final learned weights need not retain it. This is overwrite coverage, not a claim that initialization and fine-tuned weight values are identical.

The batch and single speech-tokenizer ONNX files have identical initializer fingerprints (968,038,432 bytes each), but different graphs. Milestone 1 selects single-reference enrollment. No batch graph is shipped.

`flow.decoder.estimator.fp32.onnx` is an alternate estimator representation and independent oracle. It cannot replace all of `flow.pt` because the latter also includes flow conditioning/pre-lookahead weights. Keep the ONNX oracle for validation; do not ship it in addition to a converted estimator.

`llm.rl.pt` is an alternative checkpoint excluded from the base-checkpoint milestone, not an identical duplicate of `llm.pt`. There are no optimizer, TensorRT engine or vLLM artifacts in this pinned 20-file snapshot. README and image assets are documentation, not runtime model weights.

The complete local checkpoint is intentionally retained for the official baseline. No source model files were deleted to realize these accounting reductions.
