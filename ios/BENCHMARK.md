# CosyVoice3 iOS benchmark status

Current Candidate benchmark: **PASS — physical-device public-API cold/warm evidence recorded.**

The benchmark uses the exact immutable `ios-fixed225-reference/0.1.0-rc1` private RC through `CosyVoice3Engine.synthesize()`. The first synthesis starts from a fresh process and fresh engine and does not call `validateReference()` beforehand; the repeat synthesis uses the same engine instance and identical text/reference/instruction workload. Performance numbers are measurements, not release thresholds.

Device: `iPhone18,4`, iOS `27.2`.
Engine init: `0.473 ms`.
First synthesis: `58572.106 ms`, audio `9.000000 s`, RTF `6.508012`.
Warm repeat: `61780.642 ms`, audio `9.000000 s`, RTF `6.864516`.
Output: `216000` / `216000` samples, mono Float32 PCM at 24 kHz, finite.
Asset payload tree: `a09dac47b4af1669573b31de64159cb25f9febb38585f8af0f46331e4530127f`.
Asset revision: `2fb4251057a5c627e76e392c04b0e778f530d0e0`.
Evidence: `validation/evidence/candidate_benchmark.json`.

Earlier StatefulLLMBench/full-pipeline measurements remain development provenance and are not substituted for this SDK Candidate benchmark. Core ML execution is not relabeled as proven ANE residency without independent placement evidence.
