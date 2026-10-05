# CosyVoice3 iOS benchmark status

Historical dynamic Candidate benchmark evidence: **PASS for its recorded source; current shipping source requires Candidate reclosure before this evidence can be treated as current-source authority.**

Current dynamic immutable RC: `ios-dynamic-n1-n479-reference/0.2.0-rc1@8a1f25460a157f35fe79c42a79946c40a59da08e`. Fresh-process public synthesis: 43.776 s / RTF 4.209; identical repeat on the same engine: 29.873 s / RTF 2.872. Both returned 249600 finite mono 24 kHz samples (10.4 s), default 6 steps, on physical iPhone18,4 / iOS27.2. No reference validation prewarm and no performance threshold. See `validation/evidence/dynamic_candidate_benchmark.json`. These measurements do not prove ANE residency or new human listening acceptance; the prior dynamic listening record is preserved.

The historical fixed225 benchmark uses the exact immutable `ios-fixed225-reference/0.1.0-rc1` private RC through `CosyVoice3Engine.synthesize()`. The first synthesis starts from a fresh process and fresh engine and does not call `validateReference()` beforehand; the repeat synthesis uses the same engine instance and identical text/reference/instruction workload. Performance numbers are measurements, not release thresholds.

Device: `iPhone18,4`, iOS `27.2`.
Engine init: `0.791 ms`.
Flow steps: `6` (production default).
First synthesis: `50959.334 ms`, audio `9.000000 s`, RTF `5.662148`.
Warm repeat: `5758.416 ms`, audio `9.000000 s`, RTF `0.639824`.
Output: `216000` / `216000` samples, mono Float32 PCM at 24 kHz, finite.
Asset payload tree: `a09dac47b4af1669573b31de64159cb25f9febb38585f8af0f46331e4530127f`.
Asset revision: `2fb4251057a5c627e76e392c04b0e778f530d0e0`.
Evidence: `validation/evidence/candidate_benchmark.json`.

Earlier StatefulLLMBench/full-pipeline measurements remain development provenance and are not substituted for this SDK Candidate benchmark. Core ML execution is not relabeled as proven ANE residency without independent placement evidence.
