# CosyVoice3 iOS validation and release status

This file records CosyVoice3-specific validation status and evidence against this engine's `SDK_RELEASE.md` release contract.

Current status: Technical Distribution-Ready Candidate on immutable private RC; public redistribution is not authorized.

PASS: private validation publication source is `Ashtabula/Cosyvoice/ios/`; formal external target is a fresh-history `actacomes/Cosyvoice` SDK snapshot after Production gates.
PASS: canonical maintained SDK source is `Ashtabula/Cosyvoice/ios/`; migration provenance is locked to `Ashtabula/CosyVoice3_NPU@878940245562bcd1dd0231d78157ba78d70b39f6`.
PASS: standalone Swift package, Sources and Tests are present.
PASS: stable public `CosyVoice3Engine` contract is present.
PASS: native fixed224 text/prompt prefill, stateful LLM, Swift RAS, Flow and HiFT are wired to PCM for the fixed225 profile.
PASS: EOS/stop-token semantics from the 8789402 audit are centralized and tested.
PASS: custom-reference source path includes AVFoundation resampling, native Whisper128/Kaldi80/Matcha80 DSP, Core ML speech-tokenizer/CAMPPlus calls and dynamic Flow conditioning.
PASS: custom-reference activation is fail-closed behind `PASS_DEVICE_PARITY`.
PASS: fixed-profile reference manifest, structural validator, conversion tools and example asset manifest are present.
PASS: benchmark application source is not copied into `Sources/`.
PASS: `swift test --package-path ios` passed at commit `44da9c1144e78273ea1e635b3641afdf73bf5904` (Actions run 37007257072).
PASS: accelerator status remains not-claimed.
PASS: converted speech-tokenizer/CAMPPlus candidates passed numerical parity against upstream ONNX.
PASS: native fixed-profile reference DSP passed the bounded host guardrails, including exact consumed prompt-token equality at the Flow boundary.
PASS: dynamic Flow-conditioning candidate passed host parity for mu/spks/cond.
PASS: complete custom-reference host gate emitted `PASS_HOST_PARITY`.
PASS: physical iPhone public API custom-reference smoke emitted finite mono 24 kHz PCM and is cryptographically bound to the host parity receipt.
PASS: user listening acceptance is recorded as `GOOD SOUND`.
PASS: custom-reference lane is promoted to `PASS_DEVICE_PARITY`.
PASS: complete fixed225-reference runtime is uploaded as an immutable private Hugging Face RC and the exact hosted revision passes ordinary-developer fetch plus physical public-API replay.
PASS: private-RC SDK integration boundary is frozen as `sdkIntegrationReady=true`.
PASS: physical iPhone 10/8/6 head-to-head used identical tokens/reference/noise/model instances, and the exact 6-step WAV is recorded as accepted for the production default in `validation/evidence/flow6_listening_acceptance.json`.
PUBLIC API POLICY: CosyVoice3 intentionally exposes only the physically validated `CosyVoice3FlowSteps` choices 6/8/10 to advanced SDK users, with 6 as production default. Arbitrary Flow step counts, scheduler formula/timesteps, shard topology and compute placement remain private.

PASS: current-source standalone build and supported full-runtime rebuild evidence are regenerated and bound to this promotion commit.
PASS: controlled physical-device cold/warm benchmark through CosyVoice3Engine public API validates production default flowSteps=6.
PASS: Candidate `validation/release_receipt.json` ties current source, rebuild, immutable assets, parity, device PCM and 6-step benchmark evidence together.

PRODUCTION BLOCKER: clean-room consumer integration has not run.
PRODUCTION BLOCKER: release-tree reproducibility has not been frozen.
PRODUCTION BLOCKER: asset redistribution license review remains incomplete.
PRODUCTION BLOCKER: public release identity review/fresh public snapshot has not run.
PRODUCTION BLOCKER: immutable public runtime asset publication remains pending until clean-room/license approval.
PASS FOR PRODUCTION EVIDENCE: human audio review is already recorded and need not be repeated unless runtime/audio behavior changes.

Candidate engineering gates are complete. Do not label Production or authorize public runtime assets until the remaining Production blockers pass.

PRODUCTION TOOLING READY / NOT YET PASS: `validation/ProductionCleanRoom`, `run_production_clean_room.sh`, `record_release_tree_reproducibility.py`, repository public-identity gate and fresh-snapshot exporter are implemented. Clean-room/reproducibility/identity gates remain blockers until their exact-current-tree receipts are recorded; license review remains human-gated and public assets remain private.

## Dynamic-acoustic experiment status

PASS / NOT PROMOTED: the isolated `experiment/ios-dynamic-acoustic` candidate has a complete physical N3...479 integer shape sweep (477/477, no missing/duplicates), then passed real `CosyVoice3Engine.synthesize()` on a physical iPhone for both default and custom-reference lanes after replacing simultaneous acoustic-model residency with the same one-model-per-prediction/autoreleasepool lifecycle used by the accepted shape sweep. The public-API PASS is bound to source commit `6cb25b4dba7e7540914dd3807a186767d6290110`: default N140 -> 134400 samples and reference N260 -> 249600 samples, profile `ios18-dynamic-n3-n479-candidate`, `productionPromotion=false`.

PASS / NOT PROMOTED: focused physical lower-bound extension now proves N1/N2 plus overlapping N3/N225/N479 on a fresh N1...479 package, with N0/N480 rejection and exact graph/state/CoreML-weight carry-forward equivalence. Receipt status is `PASS_N1_N2_LOWER_BOUND_EXTENSION_NOT_PROMOTED`; evidence is `experiments/dynamic-acoustic/evidence/lower-bound-n1-extension-20261004-173341-20292`.

DYNAMIC BLOCKER: the exact N1...479 integrated SDK candidate has not yet completed default + custom-reference physical public-API smoke and human listening acceptance.

DYNAMIC RISK / FAIL-CLOSED: native RAS preserves true EOS=6562 and does not suppress EOS during the frontend's minimum-token SOS suppression window, so a theoretical immediate EOS can yield N0. N0 is intentionally outside the physically validated acoustic envelope and remains fail-closed; do not change EOS semantics merely to hide this case.

The fixed225 release status and its existing production blockers above are unchanged by this experiment.

