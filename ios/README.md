# CosyVoice3 iOS SDK publication tree

Status: **Technical Distribution-Ready Candidate on immutable private RC; public redistribution is not authorized.** Publication target: `Ashtabula/Cosyvoice/ios/`.

Development source of truth remains `Ashtabula/CosyVoice3_NPU@878940245562bcd1dd0231d78157ba78d70b39f6`. The Swift package contains the application-facing `CosyVoice3Engine` and the fixed225 on-device path: native tokenizer/prefill -> stateful Core ML LLM -> Swift RAS -> Flow -> FP64-F0/HiFT -> finite mono Float32 PCM at 24 kHz. Benchmark/UI/runner code is not a runtime dependency.

The current integration profile is `ios-fixed225-reference/0.1.0-rc1`. Its complete runtime is hosted as an immutable private Hugging Face RC at `actacomes/CosyVoice-assets`, bound to revision `2fb4251057a5c627e76e392c04b0e778f530d0e0` and payload tree `a09dac47b4af1669573b31de64159cb25f9febb38585f8af0f46331e4530127f`. The exact hosted revision passed authenticated ordinary-developer fetch, validation, installation and physical-iPhone public-API replay. The Candidate flow additionally records supported full-runtime rebuild and controlled cold/warm public-API benchmark evidence, so `sdkIntegrationReady=true` and `technicalDistributionReady=true`; public redistribution remains false.

The fixed225 profile is intentionally narrow: at most 225 generated speech tokens feed a 225-token / 450-frame / 9-second acoustic bucket. Upstream stop-token handling is preserved; actual EOS is 6562, SOS is 6561, and stop IDs are 6561...6760. An early upstream stop may produce fewer than 225 tokens and remains outside the fixed acoustic bucket.

Custom reference is promoted for this profile. The runtime consumes the first 6.056 seconds of a reference and produces the fixed Flow inputs used by the current bucket: Whisper128 [1,128,605] -> 151 speech tokens, Kaldi80 [1,604,80] -> CAMPPlus [1,192], and Matcha prompt mel [1,302,80]. Flow conditioning is dynamic per request. `CosyVoice3Engine` exposes custom-reference support only when `referenceEnrollment.status == "PASS_DEVICE_PARITY"`.

Python remains conversion/validation tooling only. Shipping runtime uses Swift, AVFoundation, Accelerate, Core ML and swift-transformers. The package CI command `swift test --package-path ios` passed at publication commit `44da9c1144e78273ea1e635b3641afdf73bf5904` in GitHub Actions run 37007257072.

The same **Technical Distribution-Ready Candidate** engineering state used by ZipVoice iOS is now represented by committed evidence: one-command pinned supported full-runtime rebuild, controlled cold/warm physical-device public-API benchmark, and `validation/release_receipt.json`. Production still requires clean-room consumer integration, release-tree reproducibility and redistribution/license clearance. Human listening acceptance remains PASS.

Core ML execution and requested compute units are descriptive only; accelerator residency remains unclaimed.
