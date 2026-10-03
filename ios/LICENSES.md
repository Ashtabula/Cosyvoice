# CosyVoice3 iOS licensing and redistribution status

Repository source code is covered by the repository Apache License 2.0. Frozen migration provenance records upstream source revision `074ca6dc9e80a2f424f1f74b48bdd7d3fea531cc`; Matcha-TTS revision `dd9105b34bf2be2230f4aa1e4769fb586a3c824e` includes its MIT license.

Pinned model revision `FunAudioLLM/Fun-CosyVoice3-0.5B-2512@29e01c4e8d000f4bcd70751be16fa94bf3d85a18` declares `license: apache-2.0` in its model card. That checkpoint-level declaration does not by itself complete provenance/redistribution review for bundled CAMPPlus, speech-tokenizer, Qwen-derived weights or generated runtime assets.

The Git SDK tree contains source, tests, tools, documentation and small receipts; it does not contain the multi-GB runtime model payload. Python/ONNX Runtime dependencies recorded under `validation/provenance/` are host-side conversion/parity dependencies, not shipping Swift runtime dependencies. Shipping runtime uses Apple frameworks plus the pinned Swift package dependency in `Package.swift`.

Reference audio supplied for local validation is not authorized as a redistributed SDK asset and is excluded from the release payload.

Release license gate: OPEN. Before public redistribution, review the exact downloadable runtime asset archive, enumerate every third-party/model artifact and revision, record applicable terms/notices/restrictions, and make this file match the exact distributed payload.

Detailed historical audit notes are preserved in `docs/provenance/LICENSE_AUDIT.md`.

# Code purpose: release-facing licensing status for the exact CosyVoice3 iOS SDK/runtime distribution boundary.
# Upstream source: repository licenses, pinned model metadata and validation/provenance dependency records.
# Runtime environment: release documentation only.
# Generated time: 2026-10-03 America/New_York.
