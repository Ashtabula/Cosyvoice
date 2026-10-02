# CosyVoice3 iOS release checklist

Current status: Development.

PASS: publication target is `Ashtabula/Cosyvoice/ios/`.
PASS: source is locked to `Ashtabula/CosyVoice3_NPU@878940245562bcd1dd0231d78157ba78d70b39f6`.
PASS: standalone Swift package, Sources and Tests are present.
PASS: stable public `CosyVoice3Engine` contract is present.
PASS: native fixed224 text/prompt prefill, stateful LLM, Swift RAS, Flow and HiFT are wired to PCM for the fixed225 profile.
PASS: EOS/stop-token semantics from the 8789402 audit are centralized and tested.
PASS: custom-reference source path now includes AVFoundation resampling, native Whisper128/Kaldi80/Matcha80 DSP, Core ML speech-tokenizer/CAMPPlus calls and dynamic Flow conditioning.
PASS: custom-reference activation is fail-closed behind `PASS_DEVICE_PARITY`.
PASS: fixed-profile reference manifest, structural validator, conversion tools and example asset manifest are present.
PASS: benchmark application source is not copied into `Sources/`.
PASS: `swift test --package-path ios` passed at commit `44da9c1144e78273ea1e635b3641afdf73bf5904` (Actions run 37007257072).
PASS: accelerator status remains not-claimed.
PASS: converted speech-tokenizer/CAMPPlus candidates passed numerical parity against upstream ONNX.
PASS: native fixed-profile reference DSP passed the bounded host guardrails, including exact consumed prompt-token equality at the Flow boundary.
PASS: dynamic Flow-conditioning candidate passed host parity for mu/spks/cond.
PASS: complete custom-reference host gate emitted `PASS_HOST_PARITY` with `HOST_PARITY_COMPLETE_DEVICE_PARITY_PENDING`.

BLOCKER: dynamic Flow-conditioning/custom-reference path has not yet passed physical-device public-API parity.
BLOCKER: custom-reference public API has not yet produced accepted PCM on a physical iPhone from this publication tree.
BLOCKER: immutable hosted asset manifest/fetch path is incomplete.
BLOCKER: one-command pinned local rebuild is incomplete.
BLOCKER: no Candidate `validation/release_receipt.json` ties source, assets, parity, device, PCM and benchmark evidence together.
BLOCKER: clean-room integration has not run.
BLOCKER: model/runtime redistribution license review remains incomplete.

Do not label Candidate until all Candidate blockers have committed evidence. Do not label Production until human audio review, clean-room integration, release-tree reproducibility and license review also pass.
