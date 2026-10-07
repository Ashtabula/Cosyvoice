# Exact validated CosyVoice Runner integration audit

执行位置：本地 macOS Git repositories，2026-10-06 America/New_York。状态：BLOCKED_EXACT_VALIDATED_ASSET_MISSING；源码集成修正与 host 测试完成，原始模型未恢复，物理任务未执行。此报告不宣称整个任务完成。

1: 当前来源。Demo base c01e268a310ddee06607440e553c18aa5a9fd193；Cosy source pin 053e0efa04f46bb7083f0b8063caa5e97ebcd72b，experiment/ios-enumerated-ane-optimization。Cosy main d783f622 尚无所需 profile API，因此使用 Demo ENGINE_SOURCES.json 绑定的实际实验分支。新工作区最初不存在；已从 remote 恢复源代码，跳过 LFS。旧 physical source 与新构建 source 分开记录，未将 source-only 构建冒充 physical proof。

2: 精确资产。Current manifest 2ddc7fa084fb0e458b34f61af7fcc927773fb3697496a17f8ae1593ba33b56ee / tree 4750dba5e727276d22b71399b702a33597aaaf36d61edf8cc3dd8bd3897e6efa；Q8 manifest a276c672e178b4e87d44be96dcb24453bb45b76366270299b5977eca732dc2b5 / tree 150c0d45d6133818c782f0dfb4dcb2508f097fc42bc81e12e916aca051954f98；Hybrid manifest 4f8e3aec18152c07a0e31814c2fa9ac92c3555fc4345f22f378cc07c6aa495d8 / tree 3b57dab13798145f0f4d258c2d0e3903340594ebea85a3775f643e664b83dfd9。prefill/decode/P2 hashes、历史 device/OS/source/request/output/timing 及 evidence 文件 SHA 见 exact_validated_asset_inventory.json。这些是预期身份，不是本次已验证的实际字节。

3: 恢复顺序。权威 collection /Volumes/WD/Codes/Cosyvoice/ios/.work/weight-profile-sdk-q4-hybrid-20261006 不存在；原始 repo 目录不存在；/private/tmp/cosyvoice-llm-quantization-20261006 不存在。检查 WD 工作区/备份/开发目录、HF cache、用户下载和临时位置，未找到精确 Q8/Hybrid collection。旧 DerivedData 中有其他 Cosy 模型，未当作替代 payload。catalog 只列旧 fixed225 和 dynamic releases。经已有认证读取 HF actacomes/CosyVoice-assets 当前 revision 53e99a0529554ded273ab2f281bcaf67534198bf，未发现 weight-profile files；该可变 HEAD 不是已验证 collection revision，未下载。发布脚本的存在不能证明发布完成。未清理证据，未重新导出、转换、下载 upstream checkpoint 或生成 P2。

4: Human/semantics。三个历史 HUMAN_PASS 已读取并绑定 evidence SHA。Hybrid 只指 q4_decode_hybrid_a：同 Q8 prefill + INT4 per-channel decode + request-owned 48-state FP16 bridge，6,291,456 bytes，prefill 后一次复制。SDK 源码未改，frontend/tokenizer/reference/RAS/EOS/输出/public synthesize/acoustic/HiFT 路径保持原状，SHARDS=2、Flow6。Current 默认不变。Full-Q4-prefill、block32、重新转换和未验证 candidates 均不 staging、不选择、不比较。Full-Q4 同一生产长度 package 的 PASS/-14 历史观测不足以证明 load/relaunch 稳定，~1.27 GB 数值不用于三 profile 比较。

5: SDK/缓存。继续使用一个 CosyVoice3Engine，.current/.q8/.q4；.q4 是 Hybrid 兼容 selector。SDK 负责内部文件映射、精确 manifest/payload/prefill/decode/P2 校验，错误混合 assets 无 fallback。profile/content 身份参与 shelf/readiness/cache key；MLState 按 request 管理。此次 10 项 WeightProfileTests 全过，但 fixture tests 不替代真实包 hash 核验。

6: Runner 改动。保留现有 logical endpoint IDs 以兼容旧六项 benchmark surface；三个 endpoint 共享一个 SDK 和一个 collection，不复制 engine。一般消费者四引擎 registry 未改。本次未将既有 UI 重构成单 engine 下的三个嵌套 selector；runtime availability 因资产缺失未完成验证。Current 显示为 Cosy Current；Hybrid 显示 Q8 Prefill + Q4 Decode。新增 canonical engine=cosyvoice，profile=current|q8|hybrid_q4；保留 cosyvoice3 和旧 endpoint aliases。缺 profile -> Current；未知 profile 拒绝，host 在 device 操作前抛错。receipt Hybrid ID 归一 hybrid_q4，其他 schema 字段不变；旧 optional receipt 字段继续允许旧数据解码。共享 Cosy 配置 provenance 可用于三个 profile；source receipt pin 修正为真实 053e0ef。

7: Benchmark/energy。synthesize 的计时边界和 RTF 定义未改。现有 Sustained Playback 实现 producer -> bounded buffer -> real playback -> idle headroom，公共 stage telemetry 和 played-seconds 分母保留。源码具备 measurementRunUUID/external trace correlation；三个 profile 的物理 Sustained readiness 尚未建立。process CPU Recount 不属于 whole-device energy；Power Profiler correlation 未验证。未运行长热测试或最终 unplugged 比较。

8: 历史三方数据（充电开发环境、历史 matched N260，不是本次 Runner 数值）。Current/Q8/Hybrid payload bytes：3,530,215,890 / 2,803,735,289 / 2,621,792,999；warm median RTF：0.47999 / 0.35034 / 0.26800；total ms：4991.85 / 3643.59 / 2787.16；LLM ms：3308.46 / 1990.54 / 1158.83；decode median ms/token：12.515 / 7.433 / 4.224；sampled peak bytes：2,353,417,424 / 1,591,790,704 / 1,447,595,168；CPU-only dev mJ/audio-sec：118.95 / 120.64 / 131.25。三者短 thermal nominal -> nominal。completion/idle RAM 和各条 token/PCM/WAV identity 以 inventory 所指 physical receipt 为准，不填造缺项。MLComputePlan preferred/supported 不是 actual per-op residency。现有 profiler evidence 需与恢复资产身份核对后才能用于 ANE 拓扑结论。

9: 测试。Swift 6：73 tests，5 skipped（依赖真实资产），0 failures；10 profile tests 全过。真实生产 Swift Configuration verbatim 编译并执行 JSON decoding，和 Python supervisor routing：missing/default/Q8/Hybrid/legacy/invalid/other engines 全过。六 profile surface、资产 staging、用户 reference、runtime lifecycle contracts 全过。Swift parse / git diff --check 通过。首次 Demo Release 暴露 main 既有日志字符串 interpolation 转义错误，已仅去除表达式内错误 quote escaping，字段和中间 debug 输出保留。Demo signed Release BUILD SUCCEEDED 且 codesign strict verify 通过，所有四 SDK 链接，无 quarantine。Cosy signed Release BUILD SUCCEEDED 且 codesign strict verify 通过。两次 build 均未包含已验证模型资产，不等于物理 synthesis 或 ANE 验证。

10: 物理/默认/可选性。历史三个 HUMAN_PASS 是 YES；exact three frozen 在本机是 NO；Hybrid 定义准确 YES；Full-Q4 excluded YES；Current default YES；fixture fail-closed/cache tests YES；Runner selectors 源码存在但真实可用性 BLOCKED；formal one profile/fresh process YES；exact receipt expected 身份齐备但 actual staging identity 未取得；synthesis compatibility host PASS；Sustained physical readiness NO；Power Profiler correlation readiness 未验证；short smoke 三者均 NOT_RUN。

11: 后续门槛。只需提供保存的原始 collection 或有权威 hash 绑定的 immutable remote revision。恢复后依次核验每个文件/manifest/tree/prefill/decode/P2 与 evidence；一 profile 一 fresh process 各一短 smoke，验证 finite public PCM、no fallback、实际 receipt identity。再准备 Release/unplugged/not charging/wireless/fixed screen/comparable battery/nominal start 的 head-to-head。后续旧设备测试应先做 plan/load、短 request、Jetsam/crash/memory pressure、peak/steady RAM、RTF，再做真实 playback underrun/thermal/energy。不得由 iPhone18,4 RAM 推断旧设备支持，也不按最快单指标自动决定产品。

12: GitHub Timeline。未 commit，未 push。用户本次未要求 push，保留可 review 的本地修改；模型、缓存、构建输出未加入 Git。两仓库历史工作记录采用 append-only。

完整执行日志位于 /Volumes/WD/Codes/Demo/Clean/validation/exact_assets_20261006/，失败尝试与成功重试均保留。verification_summary.json 记录实际 executable hash、修改源码 hash、SDK cleanhouse source pins 和测试状态。
