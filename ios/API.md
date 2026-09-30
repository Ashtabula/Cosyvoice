# Proposed clone-only API and private contracts

Design only; no callable Swift synthesis engine is implemented yet.

Public boundary: initialize `CosyVoice3Engine` with an asset root; `synthesize(text:reference:)` takes target text and a reference with audio URL plus exact transcript; returns mono Float32 PCM at 24,000 Hz. App code should not receive model filenames, KV layouts, iteration counts or bucket sizes.

Reference cache version 1 must identify source/model revision, tokenizer asset hashes, frontend settings, reference WAV hash and transcript hash. Persist all required conditioning: prompt text tokens/length, prompt speech tokens/length for both LLM and flow, prompt mel features/length and speaker embeddings. Invalidate on any incompatible identity/version. Cache enrollment instead of re-encoding the reference for every sentence.

Observed fixture conditioning: prompt text [1,39], target text [1,32], both prompt speech-token arrays [1,151], prompt mel [1,302,80], both embeddings [1,192]. These are fixture shapes, not permanent API constants.

Verified checkpoint Qwen config: width 896, 24 layers, 14 query heads, 2 KV heads, head dimension 64, FFN width 4864, RoPE theta 1,000,000, RMS epsilon 1e-6. The frozen prefill embeddings are [1,224,896]; each layer's K and V are [1,2,224,64]. One-token decode consumes that cache and emits length 225 caches. A bounded runtime must make valid lengths, positions and padding masks explicit and prove cache parity before choosing production buckets.

Preferred private design: text/reference prompt assembly on host; a prefill graph; explicit per-layer K/V tensors; a one-token graph returning speech logits and updated cache; unchanged RAS host sampling. Compare FP32 first, then independently test FP16. Weight sharing across prefill/decode packages and compilation layout must be measured; two separately exported graphs can increase shipping size.

Flow checkpoint uses DiT width 1024, depth 22, 16 heads and 80-bin mel, with 25 Hz speech tokens and a 2:1 mel/token ratio. The official 10-step cosine-time Euler/CFG trajectory is captured. Scheduler stays on host; estimator conversion follows the LLM gate.

Initial enrollment may use ONNX Runtime CPU for CAMPPlus and speech tokenizer. Neural HiFT and spectral reconstruction may use different execution paths if waveform parity is retained. No ANE-residency claim follows merely from requesting cpuAndNeuralEngine.
