# CosyVoice3 ios / Apple Neural Engine Migration Brief

Status: 2026-09-29
Workspace root: `/Volumes/WD/Codes/CosyVoice3`
Upstream repository: `QwenAudio/CosyVoice`
Current upstream checkout: `074ca6d` (`main`)
Target model: `FunAudioLLM/Fun-CosyVoice3-0.5B-2512`

## 1. Objective

Begin an ios / Apple Neural Engine migration of CosyVoice3 inside the existing local CosyVoice checkout.

Do **not** attempt a complete CosyVoice3 port in one step.

The first milestone is a minimal, independently verifiable **CosyVoice3 clone-only ios engine**.

Milestone 1 must prove that zero-shot voice cloning can run locally on an iPhone while preserving acceptable speaker identity.

Do not implement emotion or instruction control in the first milestone.

The working directory is:

`/Volumes/WD/Codes/CosyVoice3`

The upstream CosyVoice source is already present in this repository.

All Apple-specific implementation should be created under:

`/Volumes/WD/Codes/CosyVoice3/ios`

The upstream Python implementation must remain available in the same checkout as the numerical and behavioral reference.

## 2. Repository layout

Use the current checkout as the source of truth:

```text
/Volumes/WD/Codes/CosyVoice3/
├── cosyvoice/                  # upstream Python implementation
├── runtime/                    # upstream deployment/runtime code
├── examples/                   # upstream examples and configs
├── third_party/
│   └── Matcha-TTS/             # upstream submodule
├── ...
└── ios/                        # our Apple/Core ML/ANE implementation
```

Create the Apple implementation inside `ios/`.

A recommended structure is:

```text
ios/
├── Package.swift
├── README.md
├── API.md
├── ASSETS.md
├── manifest.json
│
├── Sources/
│   ├── CosyVoice3Engine.swift
│   ├── CosyVoice3Contracts.swift
│   ├── CosyVoice3ReferenceEncoder.swift
│   ├── CosyVoice3TextFrontend.swift
│   ├── CosyVoice3LLMRuntime.swift
│   ├── CosyVoice3FlowRuntime.swift
│   ├── CosyVoice3HiFTRuntime.swift
│   └── ...
│
├── assets/
│   ├── assets.txt
│   ├── validate_assets.py
│   └── ...
│
├── tools/
│   ├── export_llm_prefill.py
│   ├── export_llm_step.py
│   ├── export_flow.py
│   ├── export_hift.py
│   ├── inspect_checkpoint.py
│   └── parity/
│
└── validation/
    ├── build.sh
    ├── parity/
    └── DeviceSmoke/
```

This structure should remain self-contained so that, if the engine is validated later, the entire `ios/` implementation can be migrated into `Ashtabula/NPU_engines/ios/CosyVoice3/` with minimal restructuring.

## 3. Upstream project and license

Upstream project:

`QwenAudio/CosyVoice`

Target checkpoint:

`FunAudioLLM/Fun-CosyVoice3-0.5B-2512`

The CosyVoice repository currently declares Apache-2.0 licensing.

The agent must still verify and record:

- source-code license
- model-weight license
- licenses of runtime-relevant third-party components
- licenses of any assets redistributed with the ios package

Do not assume that repository source licensing alone automatically covers every model or asset.

Record the exact upstream commit and exact model checkpoint revision used for all parity work.

## 4. Milestone 1 public behavior

Input:

- one clean reference WAV
- the exact transcript corresponding to the reference WAV
- new target text

Output:

- mono Float32 PCM
- 24 kHz
- speech using the reference speaker identity
- no per-user training
- no fine-tuning

The intended conceptual API is:

```text
assetRoot
+ target text
+ reference WAV
+ exact reference transcript
-> VoiceAudio
```

The final Swift API does not need to use these exact argument names, but the public boundary should remain similarly small.

Do not expose model implementation details to the application layer.

## 5. Definition of zero-shot voice cloning

For this project, zero-shot cloning means:

A previously unseen user provides a short reference recording and its transcript.

The system derives the required speaker/reference conditioning during enrollment or inference and synthesizes new text using that speaker identity.

There is no user-specific training step.

There is no user-specific fine-tuning step.

There is no requirement to create a new model checkpoint for each speaker.

## 6. Important upstream conditioning behavior

CosyVoice3 zero-shot conditioning is **not** just a speaker embedding.

The current upstream `frontend_zero_shot()` path derives multiple forms of conditioning from the reference.

Relevant upstream source:

`cosyvoice/cli/frontend.py`

The reference path currently produces:

- prompt text tokens
- prompt speech tokens
- prompt speech features / mel context
- CAMPPlus speaker embedding

The current upstream code constructs the zero-shot model input using values including:

```text
prompt_text
prompt_text_len

llm_prompt_speech_token
llm_prompt_speech_token_len

flow_prompt_speech_token
flow_prompt_speech_token_len

prompt_speech_feat
prompt_speech_feat_len

llm_embedding
flow_embedding
```

Therefore the ios enrollment/cache contract must preserve the complete reference conditioning required by the runtime.

Do not reduce the product model to “one speaker vector” unless numerical and listening evidence proves that the omitted conditioning is unnecessary.

## 7. Current model path

The approximate upstream runtime path is:

```text
reference WAV + exact transcript
        ↓
reference frontend / conditioning
        ↓

target text
        ↓
Qwen2 / CosyVoice3 autoregressive LLM
        ↓
discrete speech tokens
        ↓
CausalMaskedDiffWithDiT
        ↓
80-bin mel
        ↓
CausalHiFTGenerator
        ↓
24 kHz waveform
```

Relevant upstream files include:

```text
cosyvoice/cli/frontend.py
cosyvoice/cli/cosyvoice.py
cosyvoice/cli/model.py

cosyvoice/llm/llm.py

cosyvoice/flow/flow.py
cosyvoice/flow/flow_matching.py
cosyvoice/flow/DiT/

cosyvoice/hifigan/generator.py
```

The current public CosyVoice3 configuration should also be inspected directly from the released checkpoint and from:

`examples/libritts/cosyvoice3/conf/cosyvoice3.yaml`

Do not rely on copied constants when the checkpoint can be inspected directly.

## 8. Phase 0 — establish the official upstream baseline

Before converting any major model component, establish a reproducible upstream PyTorch baseline.

Use one fixed:

- reference WAV
- exact reference transcript
- target sentence
- upstream source revision
- model checkpoint revision

Generate and archive:

- final waveform
- sample rate
- duration
- all reference-conditioning tensor shapes
- representative reference-conditioning tensor values or hashes
- text tokens
- prompt speech tokens
- generated speech-token sequence
- important intermediate tensor shapes
- intermediate numerical samples required for later parity
- model/config metadata
- runtime asset sizes

Record the sampling configuration.

If complete determinism is not possible, record precisely which stages are stochastic and establish deterministic component-level parity wherever possible.

Before spending significant time on Core ML conversion, listen to the upstream clone.

The upstream clone quality must be good enough to justify the migration.

## 9. Phase 1 — determine the true shipping asset set

Do not estimate ios package size from the Hugging Face repository total.

The complete model repository is approximately 9–10 GB and contains deployment duplicates and artifacts that may not all be needed simultaneously.

Audit every large file and classify it as one of:

- required for clone-only inference
- required only for instruct/emotion
- required only for training
- optional deployment format
- duplicate representation of another model
- benchmark/test asset
- removable

Known categories that require investigation include:

- PyTorch flow weights versus exported ONNX flow
- normal speech tokenizer versus batch speech tokenizer
- base LLM versus RL LLM
- Qwen initialization / `CosyVoice-BlankEN` weights versus weights already contained in `llm.pt`
- TensorRT/vLLM deployment artifacts
- training-only checkpoints and optimizer state
- duplicate model formats

Do not package both copies of the same weights merely because upstream supports multiple runtimes.

Produce an explicit asset inventory with:

- filename
- byte size
- purpose
- whether clone-only requires it
- whether ios requires it
- whether another file duplicates the same weights
- planned ios representation

The final output of this phase must include the true **unique clone-only runtime weight size**.

Also report expected size after:

- FP16 conversion
- any validated lossless removal of duplicate assets
- any later quantization, if tested

Do not assume quantization is acceptable without numerical and listening validation.

## 10. Phase 2 — Qwen / speech-token LLM

Do not export the high-level Python or Hugging Face generation loop.

Decompose the autoregressive model into a device-oriented runtime.

Preferred architecture:

```text
text/reference prompt
        ↓
prefill graph
        ↓
explicit KV cache
        ↓
one-token decode graph
        ↓
CPU/Swift sampling
        ↓
next speech token
```

Use lessons from the existing OmniVoice ios work where appropriate:

- static graph shapes
- explicit KV cache
- bounded context buckets
- separate prefill and one-step decode
- host-side sampling
- numerical parity before latency optimization
- physical-device validation
- explicit ANE placement verification

Current upstream configuration is approximately:

- hidden size: 896
- transformer layers: 24
- attention heads: 14
- KV heads: 2
- FFN / intermediate width: 4864

Verify these values from the target checkpoint rather than treating them as permanent API constants.

Investigate:

- Core ML conversion stability
- RoPE implementation
- attention implementation
- explicit KV-cache ABI
- static maximum context sizes
- bucket strategy
- prefill graph size
- one-step graph size
- FP16 numerical behavior
- whether layer/block splitting is necessary
- ANE partitioning
- compile time
- model load time
- peak memory

Do not alter model mathematics merely to make conversion easier unless:

1. the original path has already been preserved as an oracle, and
2. numerical evidence shows the replacement is acceptably equivalent.

## 11. LLM sampling

The neural graph should produce logits.

Sampling should remain outside the Core ML graph.

Preserve the upstream sampling behavior initially.

CosyVoice uses repetition-aware sampling logic rather than a simple unconditional argmax path.

Document exactly which sampling behavior is required for parity.

If a deterministic validation policy is introduced, clearly distinguish it from the production sampling policy.

## 12. Phase 3 — Flow / DiT

CosyVoice3 uses:

`CausalMaskedDiffWithDiT`

The current architecture is approximately:

- model width: 1024
- depth: 22
- attention heads: 16
- mel dimension: 80
- speech-token frame rate: 25 Hz
- token-to-mel ratio: approximately 1:2

Verify all values from the target checkpoint.

The released model provides:

`flow.decoder.estimator.fp32.onnx`

Use this as an independent numerical oracle where useful.

Preferred ios structure:

```text
Swift / CPU scheduler
        ↓
static Core ML DiT estimator
        ↓
next flow state
        ↓
repeat
```

Do not force the complete Euler / CFM scheduler loop into one Core ML graph.

Keep scheduler state and iteration logic in Swift or host CPU code unless evidence shows another design is superior.

Use static frame-length buckets.

Validation order:

1. one estimator call
2. one scheduler step
3. multiple fixed steps
4. complete mel trajectory
5. final mel comparison
6. physical-device execution
7. ANE placement and latency

Numerical parity is more important than optimization during the first pass.

## 13. Phase 4 — HiFT vocoder

CosyVoice3 uses:

`CausalHiFTGenerator`

Relevant upstream source:

`cosyvoice/hifigan/generator.py`

Do not assume the complete vocoder must live in one Core ML graph.

Separate the problem into:

- neural F0 prediction
- convolutional / neural waveform generation
- spectral reconstruction
- ISTFT or equivalent reconstruction operations

If Core ML can run the neural portion successfully but ISTFT or related operators block stable ANE execution:

```text
neural HiFT components -> Core ML
ISTFT / reconstruction -> Accelerate / Swift
```

This is acceptable.

The first priority is:

- waveform parity
- 24 kHz output
- finite samples
- no severe artifacts
- acceptable listening quality

Do not sacrifice correctness merely to claim 100% ANE execution.

## 14. Phase 5 — reference frontend

Do not spend the first development cycle forcing every enrollment operation onto ANE.

For the first physical-device prototype it is acceptable to keep:

```text
CAMPPlus
    -> ONNX Runtime CPU

speech_tokenizer_v3
    -> ONNX Runtime CPU

mel / feature extraction
    -> Accelerate / CPU

text tokenization / normalization
    -> CPU / Swift
```

Enrollment is relatively infrequent.

The critical repeated synthesis cost is expected to be dominated by:

- autoregressive LLM
- flow / DiT
- vocoder

Optimize those first.

After a reference voice is enrolled, cache the derived reference conditioning locally.

Normal sentence synthesis should not repeatedly decode and re-encode the same reference WAV.

## 15. Reference enrollment contract

The first implementation should define an explicit internal reference-conditioning object.

Conceptually it may contain:

```text
reference transcript tokens
prompt speech tokens
prompt speech feature / mel context
speaker embedding
required lengths
format/version metadata
```

The exact internal representation is private implementation detail.

The persisted cache must be versioned so a later model or asset update cannot silently interpret incompatible conditioning data.

The public API should continue to accept the user's reference audio and transcript rather than exposing model-specific tensors.

## 16. Initial product limits

Milestone 1 should intentionally be narrow.

Use:

- approximately 5–10 seconds of clean reference speech
- one speaker
- accurate transcript
- Chinese first
- offline/non-streaming generation
- clone-only path
- fixed/bounded sequence sizes
- base checkpoint rather than RL checkpoint

Do not include in Milestone 1:

- emotion control
- free-form instructions
- streaming
- cross-lingual optimization
- arbitrary 30-second references
- arbitrary dynamic context lengths
- RL checkpoint
- TensorRT-specific runtime behavior
- vLLM-specific runtime behavior

The first milestone contract is:

```text
target text
+ validated short reference WAV
+ exact reference transcript
-> 24 kHz mono speech
```

## 17. ios public API direction

Keep the public boundary similar to the existing standalone ios voice-engine pattern used elsewhere in the project.

Conceptually:

```text
CosyVoice3Engine(assetRoot:)

synthesize(
    text,
    reference
) -> VoiceAudio
```

A reference should conceptually contain:

```text
audioURL
exact transcript
```

Output:

```text
mono Float32 PCM
24,000 Hz
```

Do not expose the following to application/frontend code:

- Qwen layer count
- attention-head count
- KV-cache layout
- flow iteration count
- DiT frame buckets
- Core ML filenames
- internal checkpoint filenames
- tokenizer implementation details
- ANE partition choices
- scheduler internals

These are private engine implementation details.

## 18. Validation gates for Milestone 1

The clone-only milestone is not complete until all applicable gates are addressed.

1. Upstream clone-only baseline produces intelligible speech.
2. Upstream speaker similarity is good enough to justify migration.
3. Reference-conditioning extraction matches upstream.
4. Text tokenization matches upstream.
5. LLM prefill numerical parity passes.
6. One-step decode logit parity passes.
7. KV-cache behavior is validated.
8. Speech-token generation is valid and stable.
9. Flow estimator single-step parity passes.
10. Complete flow / mel trajectory is acceptable.
11. HiFT output is finite.
12. Final output is mono 24 kHz PCM.
13. Final output is audibly comparable to the upstream baseline.
14. Physical iPhone execution succeeds.
15. Converted heavy graphs actually execute on the intended Apple hardware path.
16. Do not treat `.cpuAndNeuralEngine` as proof of ANE residency.
17. Record device latency.
18. Record real-time factor.
19. Record model-load latency.
20. Record peak memory.
21. Record final shipping asset size.
22. Perform a human speaker-identity A/B test against the upstream baseline.

## 19. Physical-device ANE validation

A successful Core ML prediction does not prove the graph is actually using ANE.

For every heavy converted component, explicitly investigate:

- requested compute units
- actual partition behavior
- CPU fallback
- unsupported operators
- graph splitting
- compilation behavior
- device-only failures
- memory pressure

Where possible, preserve device logs and benchmark receipts.

A graph that silently falls back to CPU is not considered an ANE migration success.

## 20. Milestone 2 — instruction and emotion

Do not begin Milestone 2 until clone-only speaker fidelity and device feasibility are established.

Milestone 2 should use the CosyVoice3 `inference_instruct2` path.

Relevant upstream behavior:

`frontend_instruct2()` builds on the zero-shot reference path.

This is important because a successful clone-only migration should allow most reference-conditioning infrastructure to be reused.

Test at minimum:

- neutral
- angry
- happy
- sad
- fearful
- excited
- restrained anger
- panic

The key evaluation is not just generic MOS.

Evaluate at least two independent dimensions:

### Speaker identity

Does the result still sound like the enrolled user?

### Emotion / instruction fidelity

Does the requested emotional performance actually appear?

Also determine whether the effect is genuinely prosodic/performance-level or merely equivalent to:

- pitch change
- speed change
- gain change
- simple post-processing

Evaluate whether instruction strength can be controlled predictably.

If instruction-conditioned zero-shot cloning succeeds, then CosyVoice3 may become a candidate to replace the current OmniVoice emotion lane.

That decision comes later and is outside Milestone 1.

## 21. Relationship to existing NPU_engines components

Do not modify the behavior of existing:

- ZipVoice
- OmniVoice
- PerformanceFX

during this CosyVoice3 feasibility work.

CosyVoice3 is currently an independent upstream checkout and independent experimental ios implementation.

The immediate workspace is:

`/Volumes/WD/Codes/CosyVoice3`

not:

`Ashtabula/NPU_engines/ios/CosyVoice3`

If the ios implementation proves successful, it can later be migrated into:

`Ashtabula/NPU_engines/ios/CosyVoice3/`

At that point it should follow the same standalone package principles as the other ios engines:

- explicit public API
- isolated Sources
- explicit assets boundary
- machine-readable manifest
- asset validator
- independent build gate
- device smoke test
- documentation
- no hidden dependency on sibling engines

## 22. Existing Dub-side research

The Dub repository contains preliminary research material:

Repository:

`/Volumes/WD/Codes/dub`

Relevant files:

```text
scripts/cosyvoice3_ane_probe.py
docs/COSYVOICE3_ANE_POC.md
```

These files are research/probe material only.

They are not the CosyVoice3 engine implementation.

The new agent may read and reuse the reasoning, checks, or experiment structure, but the real Apple implementation belongs under:

`/Volumes/WD/Codes/CosyVoice3/ios`

## 23. Development policy

Keep upstream source available as the parity oracle.

Prefer additive Apple-specific work under `ios/`.

Avoid unnecessary modification of upstream Python source.

If upstream code must be instrumented for parity capture, keep the changes minimal and clearly identify them.

Do not rewrite upstream algorithms merely for style or convenience.

Every material optimization should be justified by:

- measured correctness
- measured performance
- measured memory
- or a documented Core ML / ANE compatibility constraint

Maintain reproducibility.

Record exact:

- source commit
- model revision
- conversion-tool versions
- Core ML Tools version
- Xcode version
- macOS version
- target ios version
- target device model

## 24. Required final report

At the end of the clone-only milestone, report:

- upstream source commit
- exact model checkpoint revision
- source/model license status
- unique upstream clone-only runtime asset size
- final ios shipping asset size
- FP16 or quantization decisions
- reference frontend implementation
- LLM conversion architecture
- KV-cache architecture
- flow conversion architecture
- HiFT conversion architecture
- Core ML conversion results
- ANE partition results
- numerical parity results
- upstream versus ios audio comparison
- device latency
- real-time factor
- model-load latency
- peak memory
- speaker-clone listening result
- current blockers
- unsupported operators, if any
- CPU fallbacks, if any
- whether Milestone 2 emotion/instruction work is justified

## 25. Primary decision criterion

The purpose of this work is not merely to make CosyVoice3 compile on ios.

The migration is worth continuing only if the final system provides a practical combination of:

```text
zero-shot speaker cloning
+ acceptable speaker identity
+ acceptable audio quality
+ acceptable local latency
+ acceptable memory
+ acceptable shipping size
+ real ANE acceleration for the expensive neural components
```

If clone-only passes, proceed to the instruction/emotion milestone.

If clone-only fails fundamentally on speaker fidelity, package size, memory, or device execution, document the evidence before investing in the emotion path.
