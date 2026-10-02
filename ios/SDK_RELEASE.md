# CosyVoice3 iOS SDK release contract

This directory follows the same release architecture used by ZipVoice. Source of truth is `Ashtabula/CosyVoice3_NPU`; this publication directory is a reviewed release tree, not an independently maintained implementation. Current locked source: `878940245562bcd1dd0231d78157ba78d70b39f6`.

Development requires a standalone package entry, non-empty runtime source tree, tests/basic metadata, pinned source identity, and no false production claims.

Candidate additionally requires a complete callable public synthesis engine, canonical asset contract, immutable prebuilt fetch/validation path, reproducible local rebuild, host parity gates, physical-device execution through only the public API, real text/reference to finite non-empty mono 24 kHz PCM, cold/warm benchmark evidence, and a machine-readable release receipt.

Production additionally requires human audio review, clean-room consumer integration, release-tree reproducibility, and completed redistribution/license review for every distributed model/runtime asset.

`Sources/` must contain all runtime code. It may not depend on `StatefulLLMBench`, sibling repositories, Python at runtime, product UI, playback/document code, or developer-specific absolute paths. Conversion and benchmark tools stay outside runtime source.

Public API exposes only user-meaningful synthesis controls: target text, paired voice reference, and instruction/style control once validated. Model names, token IDs, KV layouts, sequence buckets, scheduler steps, Flow shard topology, Core ML functions, compute units, caches and diagnostic controls remain private.

Large model binaries stay out of Git. Prebuilt and rebuilt payloads satisfy one fail-closed contract. Downloaded archives are immutable and hash verified before extraction; rebuilds pin source/model/compiler identity and emit receipts.

The 8789402 semantic audit is authoritative for terminology: SOS=6561, EOS=6562, stop region=6561...6760; it records no behavior change.

Core ML execution and requested compute units are descriptive facts. Do not call execution ANE-resident without independent placement/residency evidence.
