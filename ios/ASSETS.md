# CosyVoice3 iOS assets

Status: Development; there is not yet a Candidate-quality standalone asset distribution contract.

Source checkpoint: `FunAudioLLM/Fun-CosyVoice3-0.5B-2512`, revision `29e01c4e8d000f4bcd70751be16fa94bf3d85a18`. The development audit measured and hash-checked the upstream checkpoint, but those files are not the final iOS SDK payload.

Validated development work uses Core ML artifacts for LLM prefill/decode, Flow conditioning plus FP16 Flow shards, and HiFT, with frontend/reference-conditioning inputs prepared by development tooling. Diagnostic artifact names/layouts are evidence, not yet the canonical SDK ABI.

Following the ZipVoice contract, Candidate status requires two acquisition paths converging on one canonical asset contract: an immutable prebuilt profile with archive/manifest hashes and atomic validated installation; and a one-command rebuild from pinned source/model/toolchain inputs producing the same runtime ABI and a provenance receipt.

Large model binaries remain outside Git. Not yet implemented here: `assets/assets.txt`, `assets/fetch_assets.py`, `assets/validate_assets.py`, hosted immutable archive/manifest, and one-command rebuild wrapper. These are release blockers.

Runtime/build entry points must not depend on developer-specific absolute paths. Historical validation evidence may retain such paths. No ANE residency claim follows from `.cpuAndNeuralEngine`.
