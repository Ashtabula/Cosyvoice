# Dynamic acoustic source and shape audit

America/New_York: 2026-10-03. Execution: local macOS Git repository; no Colab/Drive execution.
Release base: `4ab288d39b92d68b448c2d4b5fa011dddc29e202`, verified with GitHub `ls-remote`; experimental branch: `experiment/ios-dynamic-acoustic`.
Pinned conversion/upstream source: `878940245562bcd1dd0231d78157ba78d70b39f6` in `ios/.work/rebuild/ios-fixed225-reference/source`; checkpoint revision: `29e01c4e8d000f4bcd70751be16fa94bf3d85a18`. The separate development checkout has advanced to `72ff838a`; it is not the experiment source.
`REQUIREMENTS.md` was not found. Read project customization, recent history, SOURCE_LOCK, rebuild pipeline, Swift runtime, the pinned source exporters and official Flow/HiFT implementation before changes.

## Actual upstream relation

`CausalMaskedDiffWithDiT.inference` concatenates Q prompt speech tokens and N generated speech tokens, applies the lookahead convolutions at natural token length, then `repeat_interleave(token_mel_ratio=2)`. Thus `T=2*(Q+N)`, `P=prompt_feat.shape[1]`, `G=T-P`. `G=2*N` is conditional on `P=2*Q`, which the current profile satisfies: Q=151, P=302. Prompt/reference duration is not universally 302.
The official conditioning tensor is zeros at exactly T, with the first P frames replaced by prompt mel; this is required conditioning, not padding target speech to a bucket. The Flow decoder gets mu `[1,80,T]`, mask `[1,1,T]`, cond `[1,80,T]`; CFG expands them to two batch rows, second mu/spks/cond zero. Initial noise is the natural T prefix of official `CausalConditionalCFM.rand_noise(seed=0)`, not a token or mel padding workaround. The official final crop is `feat[:,:,P:]`, equivalent to `x[...,P:P+G]` under the above contract.

For N186: G372, T674, mel `[1,80,372]`; current HiFT stride product 8*5*3 and ISTFT hop 4 yield 480 samples/frame: 178560 samples, 7.44 seconds at 24kHz. This is expected geometry, not measured end-to-end proof.
For N225: G450, T752, PCM216000 / 9.0 seconds, the regression control.

## Hard-coded dependency map, traced in execution order

1: **LLM generation policy cap.** `CosyVoice3RuntimeContracts.swift:6-17` defines 225 and min(textTokens*20,225,512-logicalPrefixLength). `CosyVoice3NativeFrontend.swift:119` computes prepared maximum through that policy. `CosyVoice3LLMRuntime.swift:18-41` accepts a stop and immediately returns the current token list; exhaustion also returns normally. It neither enforces 225 nor pads. `CosyVoice3Engine.swift:239-255` forwards that actual list unchanged. Keep EOS, RAS and this cap unchanged through initial acoustic proof.

2: **Flow-condition input/output shape.** `export_pipeline_acoustics.Conditions` pins cond tail 450 in its constructor; target trace `[1,225]` implies lookahead sequence 376, repeated sequence 752, mu/cond `[2,80,752]`, spks `[2,80]`. `ios/tools/export_dynamic_flow_conditions.py:38-65` has the same fixed target trace and static Core ML inputs; `reference_flow_conditions.py:82` appends 450. “dynamic” there refers to reference values, not temporal N. `Engine.swift:214-232` selects baked or custom-reference model, both fixed target geometry. Prompt tensors from `ReferenceEncoder` and disk cache are fixed Q151/P302 independently of target N. The experiment changes only a separate symbolic wrapper, uses upstream natural tail `h.shape[2]-P`, and preserves original source.

3: **DiT shard shape.** Pinned `probe_flow_fixed_752.py` asserts input/output T752 and static trace inputs. `export_flow_fp16_shards.py:92,146` fixes examples to `[2,80,752]`, serialized static shapes for all six cuts `(0,4),(4,8),(8,12),(12,16),(16,20),(20,22)`. FirstShard input x/mu/cond `[2,80,T]`, mask `[2,1,T]`, t `[2]`, spks `[2,80]`; output h `[2,T,1024]`, te `[2,1024]`. Middle/final shard examples are recomputed at T752, so each boundary also has static T even though Python calls rotary from `h.shape[1]`. Final velocity `[2,80,T]`. Attention uses a broadcast `[2,1,1,T]` key mask, mathematically equivalent to the upstream nonstreaming repeated query mask. Symbolic risks include rotary arange, attention reshapes, positional convolutions, SDPA, and static-reshape lowering; not only model-description ranges.

4: **Host mask/noise shape.** `Engine.swift:496-517` loads and caches mask `[2,1,752]` and noise `[1,80,752]` from manifest buffers. Acoustic init lines25-26 rejects other geometry; lines51-77 create batch x `[2,80,752]` and perform CFG/Euler at that T. `generate_rebuild_validation_fixture.py:32-40` creates conversion-only N225 tokens, truncates upstream noise to752 and creates mask752; assembly copies these bytes. `assets/validate_assets.py:23-24` enforces exact buffer byte counts. A later dynamic scheduler must choose actual T from N and P, not reuse these cached lengths.

5: **Mel slicing.** `AcousticRuntime.swift:32-34` explicitly rejects actual N186, allocates tokens225 and copies 225 values. Lines78-79 allocate mel450 and copy `x[c*752+302+j]` for j<450; the effective slice is302:752. Both stride and end depend on fixed T/G. No Flow math change is needed to replace geometry in a separately gated runtime.

6: **F0 path.** `CosyVoice3HiFTDoubleF0.prediction` already reads G from `mel.shape[2]`, builds its natural convolution columns and `[1,G]` output. No225/450/752 executable assumptions there. Upstream `CausalHiFTGenerator.inference` computes F0 in FP64 then casts to mel dtype; preserve it. The diagnostic FP32 F0 Core ML exporter traces450 but does not define shipping acceptance.

7: **HiFT path.** AcousticRuntime lines81-90 allocate phase `[1,450,9]` and accumulate450 frames; line94 requires216000 PCM samples. Pinned `HiFTPortable(hift,450)` freezes noise to450*480 and overlap-add norm to450*480. Shipping host-phase model traces mel `[1,80,450]`, f0 `[1,450]`, phase `[1,450,9]`. Merely giving these inputs RangeDim leaves fixed noise/norm incompatible. A symbolic G implementation must slice original RNG noise at480*G and construct overlap-add normalization at actual G, retain original boundaries, phase/F0 math, convolutions and official PCM clamp. Upstream causal finalized decode produces480*G; nonfinalized streaming has lookahead/crop semantics outside this experiment.

8: **Receipt/validator/documentation only.** `SOURCE_LOCK`, fixed225 manifests/profile names, `assets/releases.json`, reference enrollment receipts/cache labels, package publication/finalization scripts, example manifest, unit fixtures, fixed752 diagnostic probes, benchmark/Candidate/clean-room evidence describe or enforce the fixed release. They are not dynamic production entry points and must remain immutable. `rebuild_assets.sh` is explicitly fixed225-only and calls the above static exporters; do not repurpose it to overwrite accepted assets. The experiment writes a separate asset family and machine-readable receipts under `.work/dynamic-acoustic`.

## Cross-project implementation evidence read

OmniVoice `iOS/tools/export_omnivoice_higgs_decoder_dynamic.py` starts with `torch.export.Dim` and `dynamic_shapes`, lowers TRAINING via `run_decompositions({})`, then converts an ExportedProgram with Core ML RangeDim. It materializes only reshape axes proven static by graph metadata, preserving symbolic F. Same serialized package is tested at multiple F values. `OMNIVOICE_ANE_BENCHMARK.md` documents early macOS success but iPhone E5RT/BNNS first-prediction shape failure; later dynamic Higgs succeeded. Host success does not establish device success or ANE residency.

ZipVoice `convert_fm_decoder_coreml_adaptive.py` uses symbolic shared T and branch-free downsampling preserving natural boundary behavior; `convert_vocos_coreml_adaptive.py` uses symbolic G, while noting its approximation scope. Those approximations are not imported here. HTP `MILESTONES/S24U.md` section4.9 documents rejected fixedG938 zero-padding: fake tail changed temporal convolutions and boundaries (G183 RMSE~0.00430); successful replacement used natural-G CPU ONNX. Static multibucket HTP/TPU deployment evidence does not establish padding equivalence for this model or a dynamic Core ML failure.

## Gates

Phase1A: exact pinned-source conditioning interception -> eager symbolic wrapper -> ExportedProgram -> one serialized Core ML package at N186/N225. Synthetic fixture prefixes are explicitly shape probes, not newly measured real LLM trajectories.
Phase1B: only shard0 after understanding conditioning. Phase2 requires genuine symbolic shard0 and N186/N225 validation. Preserve separate CPU_ONLY and CPU_AND_NE receipts and failure phases. No all-six export, shipping runtime change, dynamic HiFT promotion, full-device synthesis, or cap removal before their gates.
The user's attachment ends at Phase5 “Then find”; missing follow-on requirements requested separately.
