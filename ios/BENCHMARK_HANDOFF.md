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
- SDK-provided model asset identity;
- immutable staged tree/source provenance supplied by clean-room automation;
- SHARDS=2 and Flow6 benchmark contract;
- state bridge description for Hybrid4.

Runner must not encode Core ML filenames, conversion recipes, private shard paths, or bridge implementation code.

## Asset roots

Formal Runner staging uses three distinct generic folders:
- `VoiceAssets/cosyfull`
- `VoiceAssets/cosy8bit`
- `VoiceAssets/cosyhybrid4`

Each folder contains the exact corresponding immutable profile root. The SDK validates manifest/payload/model/P2 identities and fails closed. No fallback to another Cosy profile is permitted.

## Process isolation

Formal head-to-head order is one provider per fresh app process:
`zipvoice`, `omnivoice`, `voxcpm15`, `cosyfull`, `cosy8bit`, `cosyhybrid4`.

Interactive Run All remains diagnostic; the host supervisor is the strongest comparison surface because it launches every provider separately.

## Full-Q4

Full-Q4-prefill is validation history only. Do not expose a provider, asset key, CLI alias, UI label, or comparison column for it.
