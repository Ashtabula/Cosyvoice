# CosyVoice3 iOS API

Status: Technical Distribution-Ready Candidate on immutable private RC; public redistribution is not authorized.

```swift
let engine = try CosyVoice3Engine(assetRoot: assetRoot)
let audio = try await engine.synthesize(
    text,
    parameters: CosyVoice3Parameters(
        reference: optionalReference,
        instruction: optionalInstruction,
        flowSteps: .steps6
    )
)
```

`CosyVoice3VoiceReference(audioURL:transcript:)` pairs local reference audio with its exact transcript. Both values are required together. `CosyVoice3Parameters` exposes optional `reference`, optional `instruction`, and `flowSteps`. The validated public Flow choices are `.steps6`, `.steps8`, and `.steps10`; omitting `flowSteps` defaults to `.steps6`. Arbitrary integers are not accepted. Development evidence at source commit 8789402 includes Instruct2 controls for happy, angry, fast, soft and Sichuan-style prompts; that evidence does not make those labels a frozen SDK enum or guarantee arbitrary instruction quality.

`CosyVoice3Audio` contains `samples: [Float]`, `sampleRate: Int`, and `channels: Int`. The validated output contract is finite mono Float32 PCM at 24,000 Hz.

`CosyVoice3Engine` owns tokenizer/frontend assembly, reference DSP and learned reference encoders, speech-token generation, RAS behavior, Flow conditioning and the validated selectable 6/8/10-step scheduler path, FP64-F0/HiFT synthesis, model lifetime and Core ML execution. The production default is 6 steps. Custom reference is fail-closed: it is exposed only when the runtime manifest records `referenceEnrollment.status == "PASS_DEVICE_PARITY"`.

Deliberately private: physical/logical prefill length, 512-position state capacity, speech-token IDs, SOS/EOS/stop IDs, top-k/top-p/RAS internals, KV tensor names/shapes, Flow shard layout, CFG value, scheduler integration formula/timesteps, Core ML function names, compute units, placement assumptions, cache keys, diagnostic state snapshots and benchmark controls. Only the validated high-level Flow step choices 6/8/10 are public.

The immutable `ios-fixed225-reference/0.1.0-rc1` private asset profile passed ordinary-developer fetch plus physical public-API replay. Current-source Candidate evidence now additionally includes the supported full-runtime rebuild, controlled cold/warm public-API benchmark at flowSteps=6, and `validation/release_receipt.json`; Production/public release remains separately gated.

Token semantics: speech IDs 0...6560; SOS 6561; actual EOS 6562; task 6563; fill 6564; stop/special region 6561...6760. Upstream `ignore_eos=True` masks only 6561/SOS before minimum length; it does not mask actual EOS 6562.

Core ML execution is descriptive; no ANE residency claim is made without separate placement evidence.
