# Rebuild provenance — 2026-10-06

本次用户“包括”明确授权模型重建、物理重验证、通过门槛后的 HF 上传与 Runner 集成。原始字节因误删除不可恢复；上一轮 EXACT_VALIDATED_ASSET_MISSING 报告原样保留并通过 authorization_and_prior_audit.json 记录 SHA。新文件身份和输出证据独立记录，历史 HUMAN_PASS 不自动迁移。

转换源码：Cosyvoice@053e0efa04f46bb7083f0b8063caa5e97ebcd72b 的独立 clean clone；enumerated exporter 与旧 ac31e117938ed50132365973a103cc8425942700 完全无 diff。基础源码 Ashtabula/CosyVoice3_NPU@878940245562bcd1dd0231d78157ba78d70b39f6；Matcha dd9105b34bf2be2230f4aa1e4769fb586a3c824e；原始 checkpoint FunAudioLLM/Fun-CosyVoice3-0.5B-2512@29e01c4e8d000f4bcd70751be16fa94bf3d85a18。基础环境由冻结 requirements-rebuild.txt 创建；enumerated 单独 Python3.11、torch2.7.0、coremltools9.0、numpy1.26.4、scipy1.13.1，其他依赖按其 requirements 和独立 validate_conversion_environment gate。Python3.11.17，完整 resolved freeze 已保存在本目录；基础 torch2.3.1/coremltools9/numpy1.26.4，enumerated/量化 torch2.7.0/coremltools9/numpy1.26.4/scipy1.13.1。

Current 配方：执行已有 rebuild_assets.sh 生成基础 LLM/reference/FP64 F0 与上游 fixture；enumerated exporter 绑定 schema2 shared source HF revision 8a1f25460a157f35fe79c42a79946c40a59da08e 与 tree3f7b9239...，四 exact-shape multifunction families N1...450，禁止 padding/crop；随后保留原数学的 P2 repack，Flow6。每个新模型包/manifest/tree/P2 必须重新核验。

Q8：历史 conversion_receipt 与 quantize_llm_weights.py，coremltools9 linear_quantize_weights，169 linear.weight matrices，linear_symmetric/int8/per_channel/weight_threshold2048；保持 source spec、IO/state 和 arithmetic graph。Current host gate 通过之前不执行。

Hybrid：新 Q8 prefill + rescue-A int4/per_channel/linear_symmetric/169 matrices/weight_threshold2048 decode；FP16 IO/state，48-state request-level bridge 源码保持 accepted semantics。历史通用量化脚本会同时生成 Q4 prefill/decode；本任务必须加明确 decode-only 限制后才可执行。Full-Q4 prefill 不构建、不上传、不运行。

执行位置：本地 macOS /Volumes/WD/Codes/Demo/Clean/rebuild-20261006，非 Colab/Drive。iPhone Air / iPhone18,4 / UDID00008150-000A05CA1440401C / iOS27.2 已通过 USB 连接，CoreML DeviceState CONNECTED。基础 rebuild PASS_SUPPORTED_FULL_RUNTIME_REBUILD；enumerated PASS；Current LLM224+64步 logits/hidden/48-state exact0，唯一 metadata conversion_date 变化单独保留；P2 N1/128/129/260/385/450 对六分片数学 exact0。Current static/host gate 通过后才生成 Q8 与 decode-only Q4。

三个 candidate 的新包/tree 哈希详见 NEW_ASSET_INVENTORY.json。共享 reference/tokenizer/F0/buffers 按冻结 HF shared source 的实际原字节复用，未声称这些已存在组件重新转换；全 collection 为新身份。Q8 和 Hybrid64步数值特征与历史对应量化报告逐项一致，169 matrix、IO/state/spec gate intact。

物理 signed Release：独立 revalidation-runtime commits be0e613dfdf09208573d5626579050ed81fe6fcc(Current) 与5d3371b022865ab255195ab9f624caed94aa9c31(all profiles)，仅候选 hash binding 和 source resource，未正式 promotion。Current/Q8/Hybrid 各5次 SHARDS2/Flow6 public synthesis；Current六段、Q8三段、Hybrid三段真实 WAV 均精确匹配历史人工认可 token/PCM/WAV，单独 equivalence receipts 证明可继承限定语料 human gate。新物理、ANE、发布门槛独立记录。三个新完整 Instruments trace 已通过新模型SHA/actual process-load/PID/native stage/ANE containment gate：各5 prefill+1295 decode，没有新增 coarse LLM CPU activity/fragmentation。Current cached load6 vs旧5为一次prepare/warm加五request，prediction拓扑逐项等价。Acoustic仍为CPU/GPU混合活动，per-op实际设备UNKNOWN，不声称100% ANE。Core AI原始保存故障和Time Profiler第一次漏NeuralEngine instrument的失败保留；最终官方Time Profiler+Core ML+Points of Interest+Neural Engine trace独立新采集，未迁移旧trace。

历史失败 receipt、metadata gate 诊断、初始设备 staging marker 缺失、collector调用cwd错误均保留；collector cwd 仅影响最后 Git binding，native PASS/WAV 已落盘并校验，不伪称 host collector PASS。Full-Q4 prefill 未生成。HF 尚未发布，Runner新身份集成等待 ANE 门槛。
