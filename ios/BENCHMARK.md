# CosyVoice3 iOS benchmark status

Historical Candidate benchmark: **PASS for source commit 3e78a73679a144342818a41ec320a78dafda0e66; stale for the current SDK source.**

This historical benchmark uses the exact immutable `ios-fixed225-reference/0.1.0-rc1` private RC through `CosyVoice3Engine.synthesize()`. It predates the public Flow-default/API change and therefore does not establish performance for the current production default of 6 steps. A new current-source Candidate benchmark is required. Performance numbers below are retained only as provenance, not release thresholds.

Device: `iPhone18,4`, iOS `27.2`.
Engine init: `0.290 ms`.
First synthesis: `54073.430 ms`, audio `9.000000 s`, RTF `6.008159`.
Warm repeat: `66842.679 ms`, audio `9.000000 s`, RTF `7.426964`.
Output: `216000` / `216000` samples, mono Float32 PCM at 24 kHz, finite.
Asset payload tree: `a09dac47b4af1669573b31de64159cb25f9febb38585f8af0f46331e4530127f`.
Asset revision: `2fb4251057a5c627e76e392c04b0e778f530d0e0`.
Evidence: `validation/evidence/candidate_benchmark.json`.

Earlier StatefulLLMBench/full-pipeline measurements remain development provenance and are not substituted for this SDK Candidate benchmark. Core ML execution is not relabeled as proven ANE residency without independent placement evidence.
