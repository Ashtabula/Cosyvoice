# CosyVoice iOS Three-Profile Benchmark Checklist

Authoritative benchmark source branch: `experiment/ios-enumerated-ane-optimization`.

This checklist freezes exactly three Runner candidates. The failed Full-Q4-prefill experiment is historical evidence only and is not a supported Runner profile.

| Gate | Current | Q8 | Hybrid Q4 |
|---|---|---|---|
| Public profile ID | `current` | `q8` | `q4` |
| Runner label | Cosy Full | Cosy Q8 | Cosy Hybrid4 · Q8 prefill + Q4 decode |
| Shipping default | PASS — yes | PASS — no | PASS — no |
| Prefill representation | FP16 | INT8 per-channel weight compression | **Q8 prefill** |
| Decode representation | FP16 | INT8 per-channel weight compression | **INT4 per-channel decode** |
| Hybrid state bridge | N/A | N/A | PASS — request-owned 48-state FP16 copy once after Q8 prefill; no per-token host KV copy |
| SHARDS | PASS — 2 | PASS — 2 | PASS — 2 |
| Flow steps | PASS — 6 | PASS — 6 | PASS — 6 |
| Human listening | PASS — accepted LAST_KNOWN_GOOD checkpoint | PASS — explicit user review | PASS — explicit user “All good” |
| Public synthesize | PASS | PASS | PASS |
| Wrong/mixed assets | PASS — hash-gated fail closed | PASS — hash-gated fail closed | PASS — hash-gated fail closed |
| Selectable for inference | PASS | PASS | PASS |
| Full-Q4-prefill exposed | **NO** | **NO** | **NO** |

## Immutable identity

### Current
- manifest SHA256: `2ddc7fa084fb0e458b34f61af7fcc927773fb3697496a17f8ae1593ba33b56ee`
- payload tree SHA256: `4750dba5e727276d22b71399b702a33597aaaf36d61edf8cc3dd8bd3897e6efa`
- prefill package identity: `3fe257e2d8659abc7cc6de6c7b17d72510d55ef691f4323410e6bc9a44351c59`
- decode package identity: `c5207c467c19808f14174b239c2a81099970b5c2ba01277720ef985416710d0d`
- runtime payload bytes: 3,530,215,890

### Q8
- manifest SHA256: `a276c672e178b4e87d44be96dcb24453bb45b76366270299b5977eca732dc2b5`
- payload tree SHA256: `150c0d45d6133818c782f0dfb4dcb2508f097fc42bc81e12e916aca051954f98`
- prefill package identity: `f0b183e1b22a4ffccfc2c95926a0bee921d740543b4b89e40b0894a407b4a280`
- decode package identity: `ce2beac8170a210f3c4d24e4a15b487f5135df69f6a32fdac516183b4ed7c7f5`
- runtime payload bytes: 2,803,735,289

### Hybrid Q4 — q4_decode_hybrid_a
- manifest SHA256: `4f8e3aec18152c07a0e31814c2fa9ac92c3555fc4345f22f378cc07c6aa495d8`
- payload tree SHA256: `3b57dab13798145f0f4d258c2d0e3903340594ebea85a3775f643e664b83dfd9`
- prefill package identity: `f0b183e1b22a4ffccfc2c95926a0bee921d740543b4b89e40b0894a407b4a280` (same Q8 prefill)
- decode package identity: `4685dcbfe07df1e06ece018f9e0cd5184405ea29440c2d3ed85e4116bcb9ca46`
- runtime payload bytes: 2,621,792,999
- state bridge: Q8-prefill → Q4-decode request-level FP16 state-copy bridge, 48 states / 6,291,456 bytes, one copy per request.

The accepted P2 acoustic partition identities are shared and byte-identical across the three profiles. Profile/content identity participates in asset validation and the existing runtime cache identity. No profile selection uses a mutable global.

The stable public profile metadata now exposes content identities for the profile manifest, prefill model and decode model, plus prefill/decode representation, state-bridge mode, SHARDS=2 and Flow6. These are hashes/descriptions only; private Core ML filenames and conversion paths remain engine-internal.

For Runner staging, the preferred layout is one immutable collection root containing `current/q8/q4` plus shared `FlowPartitions`. The three logical Runner providers may share this collection on disk because each formal measurement starts a fresh process and the SDK resolves/validates only the requested profile child.

## Matched physical comparison already available

Matched source `1b1d3426d1188d5e45da40b81c02152b5461251f`, physical iPhone, N=260, SHARDS=2, Flow6, short nominal runs, charging-connected development telemetry:

| Metric | Current | Q8 | Hybrid Q4 |
|---|---:|---:|---:|
| Warm median RTF | 0.47999 | 0.35034 | 0.26800 |
| Warm median total ms | 4991.85 | 3643.59 | 2787.16 |
| Warm median LLM ms | 3308.46 | 1990.54 | 1158.83 |
| Decode ms/token median | 12.515 | 7.433 | 4.224 |
| Sampled peak process bytes | 2,353,417,424 | 1,591,790,704 | 1,447,595,168 |
| CPU-only dev energy mJ/audio-s | 118.95 | 120.64 | 131.25 |
| Short thermal | nominal→nominal | nominal→nominal | nominal→nominal |

These energy counters are development/process telemetry, not whole-device energy. No sustained unplugged thermal/Power Profiler conclusion is claimed.

## Human evidence

- Current: `ios/validation/listening/quality_gate_state.json` — LAST_KNOWN_GOOD human listening PASS.
- Q8: `ios/validation/evidence/llm_quantization_20261006/q8/human_review.json` — explicit PASS on three English pairs.
- Hybrid Q4: `ios/validation/evidence/q4_human_acceptance_20261006/human_review.json` — explicit HUMAN_PASS (“All good”) including the long MAX_LENGTH sample.

## Full-Q4 exclusion

The historical INT4 block32 prefill candidate failed physical Core ML execution-plan creation with error -14 before prediction/PCM. It remains preserved under validation evidence but is not selectable through the ordinary public profile API and must not be mapped into NPU_engines_Demo.

## Remaining formal comparison gate

Runner integration should use one provider/profile per fresh process. Final product comparison still requires Release, unplugged/not charging, fixed screen policy, comparable nominal start, wireless host control where needed, Sustained Playback, and supported whole-device Power Profiler correlation.
