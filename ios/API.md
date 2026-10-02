# CosyVoice3 iOS API

Status: target public boundary; the end-to-end facade described here is not implemented in the current Development package.

```swift
let engine = try CosyVoice3Engine(assetRoot: assetRoot)
let audio = try await engine.synthesize(
    text,
    parameters: CosyVoice3Parameters(
        reference: optionalReference,
        instruction: optionalInstruction
    )
)
```

`VoiceReference(audioURL:transcript:)` is local reference audio plus its exact transcript. Both values are required together. `CosyVoice3Parameters` should expose only user-meaningful CosyVoice controls: the planned fields are `reference` and optional `instruction`. Development evidence at source commit 8789402 includes Instruct2 controls for happy, angry, fast, soft and Sichuan-style prompts; that evidence does not make those labels a frozen SDK enum or guarantee arbitrary instruction quality.

`VoiceAudio` should contain `samples: [Float]`, `sampleRate: Int`, and `channels: Int`. The validated output contract is mono Float32 PCM at 24,000 Hz.

The engine must own text/reference frontend assembly, reference conditioning/cache identity, speech-token generation, unchanged RAS behavior, Flow conditioning and 10-step scheduler, HiFT synthesis, model lifetime, Core ML compilation/cache reuse, shape selection and concurrency control.

Deliberately private: physical/logical prefill length, 512-position state capacity, speech-token IDs, SOS/EOS/stop IDs, top-k/top-p/RAS internals, KV tensor names/shapes, Flow shard layout, CFG value, scheduler steps, Core ML function names, compute units, ANE placement assumptions, cache keys, diagnostic state snapshots and benchmark controls.

Current implementation note: `Sources/CosyVoice3Core/` contains low-level runtime infrastructure copied exactly from the validated development commit. It does not yet contain the end-to-end types above. Until those types exist and are exercised by a clean-room physical-device text-to-PCM test, this package remains Development.

Token semantics: speech IDs 0...6560; SOS 6561; actual EOS 6562; task 6563; fill 6564; stop/special region 6561...6760. Upstream `ignore_eos=True` masks only 6561/SOS before minimum length; it does not mask actual EOS 6562.
