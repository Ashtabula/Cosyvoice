# CosyVoice3 iOS dynamic-acoustic status

Status: **PHYSICAL N1...479 ACOUSTIC ENVELOPE + EXACT N1 CANDIDATE PUBLIC-API PASS / NOT PROMOTED**.

The frozen fixed225 release remains unchanged. This experiment branch is `experiment/ios-dynamic-acoustic`; production promotion remains false.

## Completed evidence

1. The symbolic Conditions/Flow/HiFT family covers N=3...479 with exact geometry `T=302+2N`, `G=2N`, `PCM=960N`.

2. Physical iPhone exhaustive execution completed every integer N=3...479: 477/477 PASS, no missing or duplicate N. N2 and N480 were rejected by the N3...479 package bounds. The completed evidence directory reported by the runner is:
`ios/experiments/dynamic-acoustic/evidence/acoustic-n479-sweep-n479-20261004-114716-75395`.

3. The integrated dynamic candidate root was built at:
`ios/.work/dynamic-acoustic/integration-candidate-v1/runtime`
with profile `ios18-dynamic-n3-n479-candidate`, exact fixed225 Flow-noise prefix preservation, pinned-upstream HiFT excitation provenance, and `productionPromotion=false`.

4. Physical public-API DeviceSmoke passed on source commit `6cb25b4dba7e7540914dd3807a186767d6290110` using the sequential per-prediction acoustic MLModel lifetime that matches the accepted physical shape-sweep lifecycle. Evidence directory:
`ios/validation/evidence/dynamic-public-api-smoke-1791147942`.

The PASS receipt reported:
- status: `PASS_DYNAMIC_PUBLIC_API_DEFAULT_AND_REFERENCE`
- profile: `ios18-dynamic-n3-n479-candidate`
- bounds: N=3...479
- default lane: N=140, PCM=134400 samples, 5.60 s at 24 kHz
- custom-reference lane: N=260, PCM=249600 samples, 10.40 s at 24 kHz
- source commit: `6cb25b4dba7e7540914dd3807a186767d6290110`

This proves the physical public SDK chain:
`text -> native frontend -> fixed512 stateful LLM -> native stochastic RAS/EOS -> variable N -> dynamic Conditions -> 6-step Flow -> FP64 F0 -> HiFT -> mono 24 kHz PCM`
for both default and custom-reference lanes. It does not by itself authorize release promotion or establish human listening quality.

## Lower-bound extension evidence

PASS / NOT PROMOTED: the fresh N1...479 family passed the focused lower-bound extension on a physical iPhone. Evidence directory:
`ios/experiments/dynamic-acoustic/evidence/lower-bound-n1-extension-20261004-173341-20292`.

The final extension receipt reports:
- status: `PASS_N1_N2_LOWER_BOUND_EXTENSION_NOT_PROMOTED`
- new bounds: N=1...479, T=304...1260, G=2...958, PCM=960...459840
- physical checkpoints: N1, N2, N3, N225, N479 all `PASS_SHAPE_EXECUTION`
- negative boundaries: N0 and N480 rejected
- prior exhaustive evidence carried forward: N3...479, 477 integers
- exact new family receipt SHA256: `185685c23ea6083f814dc48fbc613bd7bfed8b36901bf81530ba6abaac67b80c`
- physical device receipt SHA256: `41e49bea565f8ad59d7d92ee7145c83d1f5bbd467c448253ee02a045c7fe2c9e`
- source/weight equivalence receipt SHA256: `2ecfceafee9cb55a25d33b59ef511c1c4c03644ec7d28b0750a4b7150cbe7d81`
- production promotion: false

The carry-forward basis is exact torch.export graph code/state tensors plus exact Core ML weight payloads, with overlapping physical execution at N3/N225/N479 on the widened-range packages. The N3...479 package itself was not rewritten.

## Interior-shape clearance after public-API stall

PASS / NOT PROMOTED: after the N1 candidate public-API smoke stalled at `T=592` (`N=145`) during a Flow shard prediction, the exact widened N1...479 family was re-staged into the existing physical `AcousticShapeSweepProbe` and executed only at N145 using the accepted acoustic configuration: requested `CPU_AND_NE` plus `optimizationHints.reshapeFrequency=.infrequent`, one request-scoped MLModel per prediction, autoreleasepool lifetime.

Evidence:
`ios/experiments/dynamic-acoustic/evidence/interior-n1-interior-20261004-184558-32925`

Result:
- N145 / T592 / G290 / PCM139200: `PASS_SHAPE_EXECUTION`
- backend: requested `CPU_AND_NE`; no residency claim
- probe app uninstalled after host evidence retention

This clears the widened Core ML package and the N145 interior shape itself. The remaining hypothesis for the earlier DeviceSmoke stall is the SDK execution-configuration mismatch; current source now applies the same `reshapeFrequency=.infrequent` hint to dynamic acoustic warm and per-prediction loads. Public-API replay on the current source is still required before that diagnosis is closed.

## Exact N1 candidate public-API evidence

PASS / NOT PROMOTED: the fresh lower-bound-gated integration candidate passed real `CosyVoice3Engine.synthesize()` on a physical iPhone for both default and custom-reference lanes after the SDK was aligned to the accepted physical acoustic execution configuration.

Candidate root:
`ios/.work/dynamic-acoustic/integration-candidate-n1-v4/runtime`

Evidence:
`ios/validation/evidence/dynamic-public-api-smoke-1791154976`

Receipt:
- status: `PASS_DYNAMIC_PUBLIC_API_DEFAULT_AND_REFERENCE`
- profile: `ios18-dynamic-n1-n479-candidate`
- bounds: N=1...479
- source commit: `3267547f6436444e72889d443a030fd9be41e2af`
- default lane: N=134, PCM=128640 samples, 5.36 s at 24 kHz, WAV SHA256 `5ef55fa0efb9b0e2b0919c5d7f4cd86ddfecddebf25389e527768d5b8544a21e`
- custom-reference lane: N=260, PCM=249600 samples, 10.40 s at 24 kHz, WAV SHA256 `24a20a7aca6d6810d54184c20feccba506552b98d47b2292bb02cf99a59b6f1b`
- requested placement: LLM prefill/decode `CPU_ONLY`, dynamic acoustic `CPU_AND_NE`, reference encoders `CPU_ONLY`
- dynamic acoustic execution hint: `reshapeFrequency=INFREQUENT`
- placement/hint meaning: requested Core ML configuration only; no accelerator-residency claim
- production promotion: false

This closes the earlier N145/T592 DeviceSmoke stall as an SDK execution-configuration mismatch rather than a widened-family shape failure: the exact N145 family shape passed the focused physical probe, and the corrected SDK then completed the full default/reference public-API smoke on the N1 candidate.

## Remaining gates before dynamic promotion

1. Perform explicit human listening acceptance on both exact N1-candidate smoke WAVs using `ios/validation/record_dynamic_listening_acceptance.py`.
2. Record/quantify the theoretical native-RAS N0 case without changing EOS=6562 suppression semantics; N0 remains fail-closed unless a separately justified zero-token policy is adopted.
3. After those dynamic-specific gates pass, evaluate release/clean-room/reproducibility/license/public-identity requirements for dynamic promotion.

N0 remains an explicit fail-closed case. Actual EOS token semantics remain unchanged: EOS=6562; 6561 is SOS. The global LLM per-request capacity policy remains `min(targetTextTokens*20, 512-logicalPrefixLength)`; the active acoustic manifest provides only the downstream profile cap.
