# iOS fixed225 SDK integration-ready milestone — 2026-10-02

Status: **PASS — private-RC SDK integration ready / not yet Technical Distribution-Ready Candidate**

This milestone freezes the current CosyVoice3 iOS fixed225 SDK boundary for downstream private integration. It deliberately uses a lower readiness level than the ZipVoice iOS `Technical Distribution-Ready Candidate` milestone because three Candidate engineering gates remain open.

## Frozen SDK and asset state

- Release branch: `release/ios-fixed225-sdk-ready`
- Locked development source: `Ashtabula/CosyVoice3_NPU@878940245562bcd1dd0231d78157ba78d70b39f6`
- Runtime profile: `ios-fixed225-reference`
- Asset version: `0.1.0-rc1`
- Asset host: `actacomes/CosyVoice-assets`
- Immutable asset revision: `2fb4251057a5c627e76e392c04b0e778f530d0e0`
- Asset tag: `ios-fixed225-reference-v0.1.0-rc1`
- Asset payload tree: `a09dac47b4af1669573b31de64159cb25f9febb38585f8af0f46331e4530127f`
- Tested runtime tree: `7c828aa0e36c94c67a4d4d93d811d82237781284794a69448b4e25bb7069470d`
- Public output contract: finite mono Float32 PCM, 24 kHz
- Fixed acoustic contract: 225 speech tokens -> 450 mel frames -> 216000 samples -> 9 seconds
- Custom-reference status: `PASS_DEVICE_PARITY`
- Accelerator claim: `not-claimed`

## Ordinary private developer path

The ordinary private SDK integration path is validated:

```text
CosyVoice3Engine
        |
assets/fetch_assets.py
        |
immutable ios-fixed225-reference/0.1.0-rc1 private RC
        |
hash/profile validation
        |
physical iPhone install
        |
public synthesize path
        |
finite mono 24 kHz PCM
```

The immutable private RC passed ordinary-developer fetch and physical public-API replay before release metadata was accepted. The hosted payload remains private and authenticated.

## Device and listening evidence

Committed physical-device evidence is preserved in `validation/reference-device/promotion-receipt.json` and its bound receipts. The accepted run produced 216000 finite mono samples at 24 kHz for 9 seconds on iOS 27.2, with host/device binding verified. Human listening acceptance is recorded as `GOOD SOUND`.

The later private-RC replay also passed after fetching the exact immutable hosted revision. That replay recorded 82.961297709 seconds elapsed for 9 seconds of PCM, RTF 9.217921967666665. These values are evidence that the hosted SDK path executes; they are not the required controlled cold/warm Candidate benchmark and are not release thresholds.

## Why this is SDK integration-ready

The following are already true:

- stable application-facing `CosyVoice3Engine` exists;
- runtime source is separated from benchmark/UI code;
- fixed225 text -> LLM -> Flow -> HiFT -> PCM path is wired;
- custom-reference host parity and physical-device public-API PCM pass;
- immutable private asset publication, fetch, hash validation and replay pass;
- asset identity is frozen and machine-readable;
- human listening acceptance is already recorded.

Therefore:

```text
sdkIntegrationReady = true
releaseStatus = development
technicalDistributionReady = false
publicRedistributionApproved = false
```

## Remaining Candidate gates

To reach the same **Technical Distribution-Ready Candidate** state used by ZipVoice iOS, all three remaining Candidate gates must pass:

1. One-command pinned **full-runtime** local rebuild. The existing one-command reference-enrollment conversion/parity flow does not reconstruct the complete LLM/Flow/HiFT/F0 runtime and therefore does not satisfy this gate.
2. Controlled cold/warm physical-device benchmark through the public API, with preserved receipt.
3. A committed `validation/release_receipt.json` tying source identity, immutable asset identity, parity, physical-device PCM and benchmark evidence together.

When those three gates pass, the intended transition is:

```text
releaseStatus = candidate
technicalDistributionReady = true
publicRedistributionApproved = false
```

## Remaining Production gates

After Candidate, Production/public release still requires clean-room consumer integration, release-tree reproducibility and asset redistribution/license clearance. Human audio review is already PASS and only needs repetition if runtime/audio behavior changes.

This milestone does not authorize making the private Hugging Face runtime assets public.
