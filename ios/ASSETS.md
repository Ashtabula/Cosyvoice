# CosyVoice3 iOS assets

Status: Technical Distribution-Ready Candidate on immutable private RC; ordinary fetch/replay plus current-source supported full-runtime rebuild and controlled 6-step physical-device benchmark evidence are committed; public redistribution is not authorized.

Source checkpoint: `FunAudioLLM/Fun-CosyVoice3-0.5B-2512`, revision `29e01c4e8d000f4bcd70751be16fa94bf3d85a18`. Canonical maintained SDK source: `Ashtabula/Cosyvoice/ios/`. Frozen migration provenance: `Ashtabula/CosyVoice3_NPU@878940245562bcd1dd0231d78157ba78d70b39f6`.

The ordinary developer path is `assets/releases.json -> assets/fetch_assets.py -> exact Hugging Face revision -> file/tree hash verification -> assets/validate_assets.py -> atomic activation`. Current private RC: `actacomes/CosyVoice-assets`, profile `ios-fixed225-reference`, version `0.1.0-rc1`, revision `2fb4251057a5c627e76e392c04b0e778f530d0e0`, payload tree `a09dac47b4af1669573b31de64159cb25f9febb38585f8af0f46331e4530127f`. That exact hosted revision passed ordinary-developer fetch and physical public-API replay.

The maintainer validation/rebuild path is `rebuild_assets.sh --profile ios-fixed225-reference`; it is not required by ordinary public SDK consumers and is excluded from the fresh public consumer snapshot. It reconstructs the final LLM prefill/maskwrite512 decode family, six FP16 Flow shards, Flow conditioning, host-phase HiFT, FP64 F0 coefficients, frontend/tokenizer embeddings and custom-reference models/tables from pinned inputs. Historical ignored `CosyVoice3_NPU/iOS/converted` artifacts are not rebuild inputs. A deterministic production-shape validation fixture replaces uncommitted historical large tensor fixtures.

Maintainer supported rebuild and canonical byte rebuild are distinct. The supported rebuild must satisfy the same runtime ABI, validators and host parity; it does not claim byte-identical Core ML serialization across compiler versions. Fresh rebuilt custom-reference packages remain `PASS_HOST_PARITY_REBUILT` until separately device-promoted; they are never silently relabeled with the immutable RC's device evidence.

Large model binaries remain outside Git. Runtime/build entry points do not require developer-specific absolute paths. The private RC remains authenticated and `publicRedistributionApproved=false` until the separate Production license/redistribution gate passes. No ANE residency claim follows from requested Core ML compute units.
