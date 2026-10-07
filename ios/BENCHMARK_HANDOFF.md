# BENCHMARK_HANDOFF

NPU_engines_Demo must treat the three Cosy designs as three independent benchmark endpoints while still using one public CosyVoice3 SDK implementation.

## Public calls

- Cosy Full: `CosyVoice3Engine(assetRoot: profileRoot, profile: .current)`
- Cosy Q8: `CosyVoice3Engine(assetRoot: profileRoot, profile: .q8)`
- Cosy Hybrid4: `CosyVoice3Engine(assetRoot: profileRoot, profile: .q4)`

`.q4` is the accepted `q4_decode_hybrid_a`: **Q8 prefill + INT4 per-channel decode**. It is not full Q4.

The old initializer `CosyVoice3Engine(assetRoot:)` remains Current/default for ordinary consumers.

## Runner-visible metadata

Runner may retain only stable public profile facts:
- profile ID/display name;
- compression description;
- experimental/default status;
- SDK-provided model, manifest, prefill and decode content identities;
- immutable staged tree/source provenance supplied by clean-room automation;
- SHARDS=2 and Flow6 benchmark contract;
- state bridge description for Hybrid4.

Runner must not encode Core ML filenames, conversion recipes, private shard paths, or bridge implementation code.

## Asset collection

Formal Runner staging uses one frozen generic collection root, e.g. `VoiceAssets/cosyprofiles`. The three logical benchmark providers all receive this same collection URL, then construct the public SDK with `.current`, `.q8`, or `.q4`.

The collection contains the three immutable profile children plus their shared byte-identical P2 acoustic assets. The SDK resolves only the requested child and validates manifest/payload/prefill/decode/P2 identities before prediction. Missing, stale, mixed, or wrong-profile contents fail closed; no fallback to another profile is permitted.

Sharing collection bytes is storage deduplication only. Formal comparison still launches one profile per fresh process, so loaded models, MLState, process memory and thermal history are not shared across measurements.

## Process isolation

Formal head-to-head order is one provider per fresh app process:
`zipvoice`, `omnivoice`, `voxcpm15`, `cosyfull`, `cosy8bit`, `cosyhybrid4`.

Interactive Run All remains diagnostic; the host supervisor is the strongest comparison surface because it launches every provider separately.

## Full-Q4

Full-Q4-prefill is validation history only. Do not expose a provider, asset key, CLI alias, UI label, or comparison column for it.

## Exact-byte recovery audit — 2026-10-06

Current source pin is 053e0efa04f46bb7083f0b8063caa5e97ebcd72b (the later publisher-only source commit); historical physical-tested source SHAs remain in the inventory. Validated local collection and preserved temporary Q8 location are absent. Release catalog has no three-profile revision; authenticated HF metadata at 53e99a0529554ded273ab2f281bcaf67534198bf has no weight-profile collection files. Each profile is EXACT_VALIDATED_ASSET_MISSING. Do not stage, expose new runtime availability, reconvert checkpoints, regenerate P2, or claim a new smoke PASS.

Canonical automation accepts engine=cosyvoice, profile=current|q8|hybrid_q4; missing profile is Current and unknown profile is rejected. Legacy cosyvoice3 and existing endpoint IDs remain compatible. Receipts emit hybrid_q4 while the unchanged SDK selector remains .q4. Formal automation terminates the existing app before each selected profile; separate configurations/runs provide the three-way comparison. Interactive Run All remains diagnostic.


## Rebuild authorized task update2026-10-06

New authoritative HF revision c16f38383fa261bfed317fbec2fad2c4115d690c (0.3.1-rc1), collection/tree/package/P2 identities in validation/rebuild_20261006/NEW_ASSET_INVENTORY.json. Current/Q8/Hybrid rebuilt host/physical/topology/exact-approved human-equivalence gates PASS; clean remote204 hashes PASS. New public metadata/default selection and Swift6 tests PASS. See validation/rebuild_20261006/BENCHMARK_HANDOFF.md for current handoff. Earlier missing-byte audit above is historical and retained; final Runner smoke is still pending.
