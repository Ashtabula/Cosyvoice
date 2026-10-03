# CosyVoice3 iOS SDK release contract

Updated: 2026-10-03.

This file defines the release architecture and acceptance boundary for the standalone CosyVoice3 iOS SDK in `Ashtabula/Cosyvoice/ios/`. It is owned by this engine repository. External applications, benchmark runners and demos are consumers only; they are not release authorities and are not runtime/build dependencies.

## Canonical package boundary

```text
ios/
├── Package.swift
├── Sources/CosyVoice3Core/
├── Tests/CosyVoice3CoreTests/
├── README.md
├── API.md
├── ASSETS.md
├── VALIDATION.md
├── BENCHMARK.md
├── LICENSES.md
├── SDK_RELEASE.md
├── manifest.json
├── SOURCE_LOCK.json
├── assets/
├── tools/
├── validation/
├── MILESTONES/
└── docs/provenance/
```

Shipping runtime is `Package.swift + Sources/`. Tests, conversion tools, benchmarks, receipts, provenance and migration material are non-runtime release engineering support. Large runtime model payloads remain outside Git.

## Source and provenance

The canonical maintained SDK source is `Ashtabula/Cosyvoice/ios/`. `Ashtabula/CosyVoice3_NPU@878940245562bcd1dd0231d78157ba78d70b39f6` is frozen migration provenance for the implementation baseline, not a second maintained SDK tree. The pinned model is `FunAudioLLM/Fun-CosyVoice3-0.5B-2512@29e01c4e8d000f4bcd70751be16fa94bf3d85a18`.

Historical migration plans and detailed audit notes belong under `docs/provenance/`; they do not define the current public SDK contract.

## Public API contract

The public entry point is `CosyVoice3Engine(assetRoot:)`. Synthesis accepts target text plus user-meaningful controls only: optional paired reference audio/transcript, optional instruction text, and validated `CosyVoice3FlowSteps` values 6/8/10. Production default is 6. Arbitrary Flow step counts are not accepted.

The output contract is finite mono Float32 PCM at 24,000 Hz. The engine owns text/token frontend assembly, reference preprocessing/enrollment, speech-token generation, RAS behavior, Flow conditioning/scheduling, HiFT/F0 synthesis, cache/model lifetime and Core ML execution.

Model filenames, graph names, token IDs, KV layouts, physical/logical sequence lengths, Flow shard topology, scheduler formula/timesteps, CFG internals, Core ML function names, compute-unit selection, cache topology and diagnostic controls remain private. Exposing the validated high-level 6/8/10 quality/performance choices does not expose scheduler internals.

## Runtime isolation

`Sources/` must be self-contained. Shipping runtime may not depend on another engine implementation, benchmark/demo/product source, reader/player UI, Python, developer-specific absolute paths or a sibling repository. Maintainer-only conversion, optimization, benchmark and asset-build tooling stays outside `Sources/`.

`validation/audit_source_isolation.py` is the fail-closed static gate for this boundary.

## Asset contract

Ordinary developers use `assets/releases.json -> assets/fetch_assets.py -> assets/validate_assets.py` to fetch and atomically activate an immutable asset profile. Advanced developers use `rebuild_assets.sh --profile ios-fixed225-reference` to reconstruct the supported runtime from pinned inputs.

Downloaded and rebuilt payloads must converge on the same runtime ABI and validator. Hash/profile mismatch, incomplete staging, incompatible reference enrollment or wrong asset identity must fail closed. Rebuilt reference assets remain host-parity-only until separately promoted on device.

Current private RC: `ios-fixed225-reference/0.1.0-rc1` at immutable Hugging Face revision `2fb4251057a5c627e76e392c04b0e778f530d0e0`. Public redistribution remains unauthorized.

## Correctness and device evidence

Candidate evidence must bind one exact SDK source commit and asset identity to: source isolation, standalone build, asset validation, supported full-runtime rebuild, host/source parity, Core ML target-runtime execution, physical iPhone public-API execution, finite text-to-PCM output and controlled benchmark evidence.

EOS terminology is fixed by the audited source contract: speech IDs 0...6560, SOS 6561, actual EOS 6562, task 6563, fill 6564, stop/special region 6561...6760. The source audit records no behavior change.

Core ML execution is descriptive. Requested compute units do not prove ANE residency; no residency claim is made without separate placement evidence.

## Release levels

Development requires a standalone package entry, non-empty runtime source, tests/basic metadata, pinned source/model identity and no false Candidate/Production claim.

SDK integration-ready is an intermediate private engineering milestone: stable public API, canonical immutable private asset profile, fail-closed validation, physical-device public-API PCM evidence and frozen asset identity.

Candidate additionally requires current-source standalone/rebuild evidence, controlled physical-device cold/warm public-API benchmark at the production default, and a complete machine-readable `validation/release_receipt.json`.

Production additionally requires clean-room independent consumer integration, release-tree reproducibility, completed redistribution/license review for the exact public payload, public-release identity review/fresh public snapshot, and immutable public runtime-asset publication.

## Current state

```text
releaseStatus = development
sdkIntegrationReady = true
technicalDistributionReady = false
publicRedistributionApproved = false
```

Already preserved: immutable private-RC fetch/replay, custom-reference host/device parity, public-API finite PCM, human listening acceptance, and physical 10/8/6 head-to-head with 6 selected as the production default.

Current Candidate blockers are only the current-source evidence closure after the Flow API/default change: regenerate source-bound standalone/full-runtime rebuild evidence, rerun the controlled cold/warm public-API benchmark at flowSteps=6, and regenerate the Candidate release receipt.

Production blockers remain clean-room independent consumer integration, release-tree reproducibility, asset redistribution/license review, public identity/fresh public snapshot, and immutable public asset publication after those gates pass.

# Code purpose: engine-owned SDK release architecture and acceptance contract for CosyVoice3 iOS.
# Upstream source: validated CosyVoice3 iOS publication history and ZipVoice-style standalone SDK release architecture.
# Runtime environment: release engineering documentation only; no runtime dependency.
# Generated time: 2026-10-03 America/New_York.
