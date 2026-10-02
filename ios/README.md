# CosyVoice3 iOS SDK publication tree

Status: Development. This is the publication target for the CosyVoice3 iOS SDK.

Development source of truth: `Ashtabula/CosyVoice3_NPU@878940245562bcd1dd0231d78157ba78d70b39f6`.
Publication location: `Ashtabula/Cosyvoice/ios/`.

The reusable Swift package scaffold from the validated development commit is present here: `Package.swift`, `Sources/CosyVoice3Core/`, and `Tests/CosyVoice3CoreTests/`. It covers Core ML model residency/compilation, shape policy, tensor/reference/prefix caches, and the validated FP16 stateful LLM session.

This is not yet a Candidate SDK. The complete text/reference -> LLM -> Flow -> HiFT -> PCM path still lives primarily in the development repository's diagnostic `StatefulLLMBench` host and has not been extracted behind a stable public synthesis facade. Benchmark/UI/runner code is intentionally not copied into `Sources/`.

The intended stable boundary follows the ZipVoice SDK rule: applications should see target text, an optional paired voice reference, and CosyVoice-specific instruction control; model filenames, KV layouts, bucket sizes, Core ML function names, scheduler steps, RAS internals, compute-unit policy, caches and worker lifecycle remain private implementation details.

Large model/runtime assets are not committed here. A canonical asset contract, immutable fetch path, fail-closed validator and one-command rebuild path are still required before Candidate status.

The exact token semantics audited at the source commit are preserved under `validation/eos-semantics-audit-20261002/`: speech IDs 0...6560, SOS 6561, actual EOS 6562, task 6563, fill 6564, and special stop IDs 6561...6760. That audit changed terminology only and did not change sampling behavior.

Accelerator claim: not claimed. Requesting `.cpuAndNeuralEngine` is not evidence of ANE residency.
