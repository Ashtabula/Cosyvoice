# CosyVoice3 iOS dynamic-acoustic status

Status: **PHYSICAL PUBLIC-API PASS FOR N3...479 CANDIDATE / NOT PROMOTED**.

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

## Current lower-bound extension gate

The N3...479 package is not rewritten in place. `run_lower_bound_extension.sh` creates a fresh N1...479 family, proves that the torch.export graph code/state tensors and Core ML weight payloads are exact relative to the accepted N3 family apart from intentionally widened shape-range metadata, then physically executes N1, N2, overlapping N3/N225/N479, and rejects N0/N480. Only a resulting `PASS_N1_N2_LOWER_BOUND_EXTENSION_NOT_PROMOTED` receipt may authorize `build_n1_dynamic_candidate.sh`.

The prior exhaustive N3...479 evidence is carried forward only when all of those equivalence and overlapping physical gates pass. No claim is made before the focused physical run succeeds.

## Remaining gates before dynamic promotion

1. PASS the focused N1/N2 lower-bound extension on the physical iPhone.
2. Build a fresh `ios18-dynamic-n1-n479-candidate` bound to that physical extension receipt.
3. Run physical default + custom-reference public-API smoke against that exact N1 candidate.
4. Perform explicit human listening acceptance on both exact smoke WAVs using `ios/validation/record_dynamic_listening_acceptance.py`.
5. Only after those gates may release/clean-room/reproducibility/license/public-identity work be evaluated for dynamic promotion.

N0 remains an explicit fail-closed case. Actual EOS token semantics remain unchanged: EOS=6562; 6561 is SOS. The global LLM per-request capacity policy remains `min(targetTextTokens*20, 512-logicalPrefixLength)`; the active acoustic manifest provides only the downstream profile cap.
