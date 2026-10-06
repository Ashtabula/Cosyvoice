# PERSISTENT_RUNTIME_ARCHITECTURE.md

需求：算法、weights、Flow default=6 / supported=[6,8,10]、LLM sampling/EOS/RoPE/KV、reference、F0/HiFT 和 public synthesis 语义保持不变。正式 source 为 `/Volumes/WD/Codes/Cosyvoice/ios`。Frozen schema-3 asset 不覆盖，实验 package 不 promotion。

1: App-owned persistent state 放在 `Library/Application Support/CosyVoice3Core/RuntimeDerived-v2`，目录设置 `isExcludedFromBackup=true`。compiled artifacts 是 derived state，不加入用户备份。旧 `Library/Caches/CosyVoice3Core` 只有 explicit FIRST_EVER_COLD lane 会清理。Production SDK 不调用 reset。

2: Generic `.mlmodelc` 以 actual package content SHA、OS/CoreML runtime、compiled ABI 定址。同一 multifunction package 的四个 functions 共用一份 generic compiled artifact。Per-model preparation records 另外严格绑定 actual manifest/payload/package SHA、schema/ABI、selected function、requested compute units 和有效 runtime hints；四个 bucket 以各自完整 model identities 定址。不会把一个 function 的 ready 用于另一个 function，也不会通过复制四套完整 weights 实现 bucket cache。

3: 每个新 process 对 immutable source root 重新做 actual-byte verification。按 4 MiB chunk 放在 autorelease pool 内，避免 Foundation `FileHandle` 桥接对象积累数 GB。使用 canonical paths，避免 `/var` 与 `/private/var` alias 影响 relative path hash。Source asset 在一个 process/Engine 生命周期内必须 immutable；更新时采用新的内容目录和 Engine，避免覆盖正在使用的模型。

4: Disk marker 表示 app-owned last validated preparation identity，不表示 Core ML 私有 execution state 一定保留。每次实际使用模型仍执行 authoritative `MLModel` load。Marker 必须同时有匹配的 model record 与 compiled artifact。Load 失败则 invalidation 并以相同 source bytes/configuration/placement 重建一次；重建仍失败则请求失败，不做 placement 或算法 fallback。系统内部 specialization/exact-N kernel cache 由 Core ML 管理，本项目不伪造它的保存/恢复状态。

5: 成功 public synthesis 后写入当前 bucket 成功记录，其它缺失 bucket 标记 PENDING_IDLE。PCM 返回后以 background-priority task 逐 bucket、逐 model 串行准备。只在 nominal 启动；fair 后完成当前不可取消 constructor 并暂停，serious/critical 不启动新工作。Active synthesis 全局优先；如果新请求到达时有 native constructor 已在执行，安全等待该 constructor 完成，不能承诺零等待。Idle model 不进入 selected-family retention shelf，构建完成即释放。

6: iOS 执行窗口为 foreground idle + finite `beginBackgroundTask`。App background/expiration 时停止启动新的 work；不宣称永久后台运行。Host 应在 foreground/nominal 通知时调用 `resumeIdleBucketPreparation()`。DeviceSmoke 有相应事件入口。验证 lane 暂时保持屏幕点亮以观察 foreground idle，完成后恢复；这不是 production thermal 策略或 sleep/throttle 优化。

7: 模型 model/function load-ready 与 observed exact-N prediction 是不同证据。Idle preparation 不调用 sampler、LLM generation 或 Flow prediction；因此四个 bucket load-ready 不能证明其中每一个 enumerated N 的首次 prediction 都没有 specialization cost。Records 保存实际成功 N；first prediction 的 opaque specialization 仍计入 acoustic execution。

8: 三条正式测量定义：FIRST_EVER_COLD 清理 app-owned derived state，但不声称能强制清空 iOS 私有 Core ML cache；PROCESS_RELAUNCH_COLD 保留缓存、结束旧 app process、启动新 process 和新 Engine；IN_PROCESS_WARM 是同 Engine 第二次 identical public synthesis。PID、source/signed binary、实际输入 SHA、N/function、PCM SHA 和 reset 状态都入 receipt。App reinstall/container migration 单独分类，不能称为同 binary relaunch。

9: 初步 physical 证据显示 same-binary relaunch 从约 40 s 降到约 8–9 s，warm 约 5 s；并未做到所有以后启动都严格等于 warm。完整 source SHA、首次 frontend、model construction/weight upload 与 exact-shape first prediction 仍有成本。App reinstall/container URL migration 已观察到再次约 38 s cold，即使 app-owned markers 存在；真实 native load 安全重新建立系统 state。OS/CoreML/ABI、模型/manifest/payload、function/placement/hints 改变、artifact 丢失/损坏或系统私有 cache 驱逐也可能失效。最终数字以 evidence JSON 为准。

10: 资源指标为 app `task_info phys_footprint` 1 Hz sample 和 OS nominal/fair/serious/critical；不是瞬时全系统峰值或持续功耗。`getrusage` app CPU time 不含所有 Core ML service/accelerator power。MLComputePlan preferred/supported devices 是 plan evidence，仍不等于每次实际 inference residency。连续合成曾进入 serious，不能把 warm latency 改善称为 sustained thermal 已解决。

上游：现有 CosyVoice3 public SDK AssetLoader/Engine 和冻结 schema-3 Core ML programs。环境：Swift6/CoreML/iOS18+、macOS/Xcode、physical iPhone18,4/iOS27.2。生成时间：2026-10-05 America/New_York。新文件；不修改 mathematical graph 或 weights。
