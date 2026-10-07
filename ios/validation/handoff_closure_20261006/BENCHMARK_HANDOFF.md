# Cosyvoice immutable public SDK handoff

Status: READY. 2026-10-06 23:42 EDT. Current/Q8/Hybrid new host/physical/ANE/fixed-human-equivalence PASS，clean204 file/package/profile/P2验证PASS。

HF: actacomes/CosyVoice-assets (private/auth required). Exact immutable revision: c16f38383fa261bfed317fbec2fad2c4115d690c. Version0.3.1-rc1. Tagios-weight-profiles-current-q8-q4hybrid-v0.3.1-rc1. Prefixios-weight-profiles-current-q8-q4hybrid/0.3.1-rc1. Collection content tree47958326989cca9ad26fe3001b03d858c205cdfa19bd5f60d19b40e16f6e54a1. Public SDK sourcecodex/cosyvoice-rebuilt-profiles-20261006@6eb42045a61015b000e40b88d6a9da0a126efce8。

ProfileIDs current/q8/hybrid_q4. DefaultCurrent. Hybrid Q4 — Q8 Prefill + Q4 Decode，public选择.hybridQ4，源代码调用.q4兼容。只有三个logical profiles；sharedFlowPartitions/p2是私有共享资产目录，不是第四profile。SDK owns mapping/hash/P2/bridge。所有required manifest/tree/prefill/decode/P2 identities及文件尺寸/全hash见NEW_ASSET_INVENTORY.json。

公共用法：CosyVoice3Engine(assetRoot: collectionRoot)选择Current；CosyVoice3Engine(assetRoot: collectionRoot, profile: .current/.q8/.hybridQ4)显式选择。未来Runner只需下载exactrevision的collection、通用fileInventory校验、collectionRoot和public selector；无需converter、torch/coremltools、fixed225、private模型文件名、shard/state flags或bridge内部。机器profile hybrid_q4不代表Full-Q4；不得暴露Full-Q4。

Scope: physical receipts at../rebuild_20261006/physical include device/source/newmodel hashes/timing/memory/CPU-onlyscope/thermal，新trace5prefill+1295decode模型hash+PIDcontainment，LLMcoarseCPU0但per-opUNKNOWN。Human PASS以当前新fixed listening PCM/WAV和原approval精确等价为依据，不移用旧trace。若改变文本、模型或采样并需quality acceptance，应另做实际WAV/human gate。

本轮handoff完成前未启动新multi-engine Runner工作；此前另一个已授权任务的三个短remote-assets smoke保持历史原记录，不改为本轮新physical执行。无final long benchmark/whole-deviceenergy claims。
