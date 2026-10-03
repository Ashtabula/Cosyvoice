# CosyVoice3 iOS SDK release contract

This directory follows the same release architecture used by ZipVoice. Source of truth is `Ashtabula/CosyVoice3_NPU`; this publication directory is a reviewed release tree, not an independently maintained implementation. Current locked source: `878940245562bcd1dd0231d78157ba78d70b39f6`.

## Release levels

Development requires a standalone package entry, non-empty runtime source tree, tests/basic metadata, pinned source identity and no false production claims.

SDK integration-ready is an intermediate engineering milestone below Candidate. It requires a stable public API, a canonical immutable private asset profile, fail-closed asset validation, physical-device public-API PCM evidence, and a frozen asset identity suitable for downstream private integration. It does not assert full local rebuild reproducibility, controlled benchmark evidence, Candidate receipt completeness or public redistribution rights.

Candidate additionally requires a complete callable public synthesis engine, canonical asset contract, immutable prebuilt fetch/validation path, a one-command pinned rebuild of the complete runtime, host parity gates, physical-device execution through only the public API, real text/reference to finite non-empty mono 24 kHz PCM, controlled cold/warm benchmark evidence, and a machine-readable `validation/release_receipt.json`.

Production additionally requires human audio review, clean-room consumer integration, release-tree reproducibility, and completed redistribution/license review for every distributed model/runtime asset.

## Current state

The `ios-fixed225-reference/0.1.0-rc1` private asset profile has immutable fetch/validation and physical-device public-API replay PASS. The custom-reference lane has host parity, device parity and human listening acceptance. Therefore this release branch records `sdkIntegrationReady=true`.

The current SDK source is intentionally below the ZipVoice iOS **Technical Distribution-Ready Candidate** milestone because the public Flow default/API changed after the last source-bound Candidate evidence. `technicalDistributionReady=false` until the current-source build/rebuild evidence, the controlled cold/warm benchmark at flowSteps=6, and the Candidate release receipt are regenerated. Public redistribution remains unauthorized until the later Production gates are closed.

## Runtime isolation and API rules

`Sources/` must contain all runtime code. It may not depend on `StatefulLLMBench`, sibling repositories, Python at runtime, product UI, playback/document code, or developer-specific absolute paths. Conversion and benchmark tools stay outside runtime source.

Public API exposes only user-meaningful synthesis controls: target text, paired voice reference, instruction/style control, and the validated Flow quality/performance choices 6/8/10 with production default 6. Model names, token IDs, KV layouts, sequence buckets, scheduler integration internals/timesteps, Flow shard topology, Core ML functions, compute units, caches and diagnostic controls remain private; arbitrary unvalidated Flow step counts are not exposed.

Large model binaries stay out of Git. Prebuilt and rebuilt payloads must satisfy one fail-closed contract. Downloaded archives are immutable and hash verified before extraction; complete-runtime rebuilds must pin source/model/compiler identity and emit receipts.

The 8789402 semantic audit is authoritative for terminology: SOS=6561, EOS=6562, stop region=6561...6760; it records no behavior change.

Reference-enrollment host parity is judged at the actual Flow-conditioning boundary. Raw Whisper/Kaldi/Matcha frontend tensors remain bounded guardrails, but backend-sensitive intermediate differences do not supersede stricter downstream checks when the shipping path transforms them before DiT consumption. Prompt speech tokens must match exactly; Flow `mu` and `spks` must satisfy their numerical gate; `cond`, which is prompt mel after only padding/duplication, uses the same bounded max/mean/p99 criterion as prompt mel. Physical-device public-API PCM parity remains mandatory before promotion.

Core ML execution and requested compute units are descriptive facts. Do not call execution ANE-resident without independent placement/residency evidence.
