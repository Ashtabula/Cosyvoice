# New immutable CosyVoice Runner handoff

2026-10-06 23:13 EDT. New rebuilt/revalidated collection supersedes missing old runtime identities.

HF repository: actacomes/CosyVoice-assets (private). Exact revision: c16f38383fa261bfed317fbec2fad2c4115d690c. Prefix: ios-weight-profiles-current-q8-q4hybrid/0.3.1-rc1. Collection tree: 47958326989cca9ad26fe3001b03d858c205cdfa19bd5f60d19b40e16f6e54a1. Remote204-file integrity PASS.

Use public CosyVoice3Engine(assetRoot: collectionRoot, profile: .current/.q8/.hybridQ4), or omit profile for Current. Machine IDs current/q8/hybrid_q4; Hybrid Q4 — Q8 Prefill + Q4 Decode. SDK owns strict runtime/LLM/P2 mapping and state bridge. Caller needs no shard flags, torch/coremltools, conversion scripts or private filenames.

Runner fetches the exact pin from COSYVOICE_ASSETS.json and verifies the generic published fileInventory; stage the same collection through existing stage_ios_voice_assets.py asset key cosyprofiles. The normal configuration uses engine cosyvoice and optional profile; missing profile Current. Existing cosyvoice3/q4 aliases remain compatible. One fresh app process per profile.

Synthesis benchmark metric definitions remain unchanged. Existing Sustained Playback lane uses the same registered public profile backend, without final long benchmark in this task. Later whole-device comparison requires Release, unplugged/not charging, wireless host control, matched battery and nominal thermal, fixed screen policy, Power Profiler. Current CPU-only process counters are not whole-device energy.

Source pin and signed Runner smoke receipts will be added after Demo remote-cleanhouse rebuild. Original EXACT_VALIDATED_ASSET_MISSING report remains unchanged.
