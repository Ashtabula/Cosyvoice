# CosyVoice3 ios / ANE migration

Status (2026-09-29): Phase 0 automatic capture/repeatability PASS; user accepted baseline listening (reply: "good"). Phase 1 measured asset audit complete, redistribution review remains open. Independent Core ML 9.0 toolchain smoke PASS on local macOS CPU. LLM FP32 prefill/decode and 226-step cache rollout pass on macOS CPU. DiT conversion runs but has not passed the fixed numerical threshold. No Swift synthesis runtime, physical iPhone or ANE claim yet.

All work runs locally in `/Volumes/WD/Codes/CosyVoice3`. Upstream Python remains unchanged. Neither Colab nor Google Drive is involved. The unrelated Dub environment is untouched.

## Evidence

Source: `074ca6dc9e80a2f424f1f74b48bdd7d3fea531cc`.
Model: `FunAudioLLM/Fun-CosyVoice3-0.5B-2512`, revision `29e01c4e8d000f4bcd70751be16fa94bf3d85a18`.
Reference: user-provided `asset/leijun-1.wav`, matching `asset/leijun-1.txt`; 24 kHz mono, 6.056708 seconds. This Chinese fixture is an explicit user-directed departure from the brief's initial English-first scope, not English validation.

Listen to `validation/phase0/run-002/baseline.wav` and compare speaker identity with the reference. Expected output text: 今天我们一起回顾过去的经历，也期待未来能够创造更多有意义的事情。

The output is 9.0 seconds, mono Float32 WAV, 24 kHz, 216,000 finite samples. Peak amplitude 0.9371465; RMS 0.0811391. PCM SHA-256: `953037c06c8cfe5c3381e005b007768d150663d543bafb6ce3beff3d6ffc72f4`.

`run-002` and `run-003` have bitwise-identical captured tensors and PCM. WAV container hashes differ only in libsndfile's PEAK timestamp. The initial `repeatability.json` records the failed container-hash assumption; `repeatability-verified.json` is the corrected, decoded-PCM and actual-tensor verification, preserving both pieces of evidence.

`run-001.log` preserves the initial SciPy 1.15.3 Mach-O import failure. Installing SciPy 1.13.1 in `.venv-upstream` fixed inference. Existing grpcio/grpcio-tools 1.57.0 generate platform compatibility warnings in `pip check`; the exercised offline clone path does not import/use them. They are not needed in the standalone Core ML environment, whose dependency check passes.

## Reproduce

Run from the repository root. The download tool reuses the pinned revision, downloads all files and verifies every size and LFS hash. Existing baseline directories are never overwritten; use a new run directory for each capture.

```sh
set -o pipefail
HF_HOME="$PWD/.cache/huggingface" .venv-upstream/bin/python -u ios/tools/download_checkpoint.py
HF_HOME="$PWD/.cache/huggingface" HF_HUB_CACHE="$PWD/.cache/huggingface/hub" TRANSFORMERS_CACHE="$PWD/.cache/huggingface/transformers" XDG_CACHE_HOME="$PWD/.cache" MPLCONFIGDIR="$PWD/.cache/matplotlib" .venv-upstream/bin/python -u ios/tools/capture_baseline.py --output ios/validation/phase0/run-004
.venv-upstream/bin/python ios/tools/verify_baseline.py ios/validation/phase0/run-002 ios/validation/phase0/run-003 --output ios/validation/phase0/repeatability-verified.json
.venv-upstream/bin/python ios/tools/audit_assets.py
.venv-coreml/bin/python ios/tools/validate_coreml_toolchain.py
```

Core ML model compilation needs access to Apple's system temporary-directory/service facilities. The sandboxed smoke failed at that boundary; the authorized unsandboxed local CPU smoke passed. This is recorded in separate logs. It is not an unsupported neural operator failure.

Environment package freezes, checkpoint hashes, host versions, asset accounting and toolchain results live under `validation/provenance/`. No model weights, environment directories or reference WAVs should enter Git. Captured `.pt` files remain local parity fixtures.

## Numerical behavior

The official `CosyVoice3.inference_zero_shot` path is used with `stream=False`, `speed=1.0`, `fp16=False`, `text_frontend=False`. This selects the official frontend bypass explicitly, retaining tokenization and complete reference conditioning. A standard neutral `You are a helpful assistant.<|endofprompt|>` prefix precedes the exact transcript; it is required by the CosyVoice3 LLM prompt format and is not an emotion instruction. Upstream prints a short-target warning based on prompt string length; the warning is retained and listening acceptance is still required.

RAS is unchanged: nucleus top-p 0.8/top-k 25, repeat window 10, threshold 0.1; repeated sampled tokens are suppressed before a full-distribution multinomial resample. EOS masking and the model's 200 stop IDs remain upstream behavior. Raw LLM emissions and the flow input tokens are both saved because the upstream LLM job also filters extended silent-token runs.

The process seed before synthesis is 1986. CausalConditionalCFM constructs a fixed Gaussian noise buffer after its own seed-0 initialization, then slices that buffer during inference. Thus its noise is not freshly sampled at each flow invocation. HiFT uses stochastic excitation; repeatability is demonstrated for these local CPU runs, not asserted across hardware or libraries.

Captures include conditioning, full first prefill and next-step KV tensors, all LLM logits and raw speech tokens, actual filtered flow tokens, all 10 estimator inputs/outputs, flow mel, HiFT inputs/outputs, RNG state and PCM. Hooks archive tensors without changing upstream math. Instrumented timing includes fixture IO: run-002 load 9.40 seconds, synthesis 22.10 seconds, RTF 2.46. These are not production latency or physical-device measurements.

## Next gate and implementation order

The migration brief Phase 0 requires listening to the upstream clone before significant conversion work. The user accepted the baseline; see `validation/phase0/listening-acceptance.json`. LLM conversion followed this gate. DiT parity diagnosis is now in progress.

After that gate: LLM prefill + one-step decode + explicit KV cache; Flow/DiT estimator with host scheduler; HiFT neural/reconstruction split; reference frontend integration; Swift runtime; physical iPhone validation. Keep exact frozen inputs as component oracles. Do not begin emotion/instruction work until clone-only quality and device feasibility pass.

See `API.md`, `ASSETS.md`, `LICENSE_AUDIT.md` and `manifest.json` for boundaries and measured/unmeasured status.
