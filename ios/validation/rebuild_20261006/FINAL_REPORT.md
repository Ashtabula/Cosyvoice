# Rebuild/revalidate/publish then Runner — FINAL_REPORT

2026-10-06 23:29 EDT / America/New_York. 本次授权任务完成：三profile权威重建、独立新身份重验证、新私有HF不可变发布和clean远端验证、公共SDK/Demo接入、三个真实签名Release Runner短smoke全部PASS。最终长时间unplugged/whole-device energy/thermal head-to-head按要求未运行。

1: 重建原因和旧审计。用户“包括”采纳后续重建/重验证/HF/Runner任务。原验证资产因误删除不可用；原EXACT_VALIDATED_ASSET_MISSING报告仍原样，authorization_and_prior_audit.json保存原SHA并再次核验。此次新包/tree身份独立，不以历史模型hash或trace冒充新资产。manifest未变化处是文件字节本身相同，包与tree新SHA仍分别记录。

2: 权威来源。checkpoint FunAudioLLM/Fun-CosyVoice3-0.5B-2512@29e01c4e8d000f4bcd70751be16fa94bf3d85a18；CosyVoice3_NPU@878940245562bcd1dd0231d78157ba78d70b39f6，Matcha@dd9105b34bf2be2230f4aa1e4769fb586a3c824e。转换独立clean Cosyvoice@053e0efa04f46bb7083f0b8063caa5e97ebcd72b，enumerated exporter与ac31e117938ed50132365973a103cc8425942700无diff。source hygiene SHA d53c3adbed082c63128daf38de0152838bd6d1cdc0b92b2a80c8521c7474ffdb；flow_input.pt SHA c4ea1c46452a1e81e05cba79737a0713fdc7a0ec0fd6a484403ba479213487a1。共享reference/tokenizer/F0/buffers按原冻结HF8a1f25460a157f35fe79c42a79946c40a59da08e/tree3f7b9239af32ba5644f1c607aa8a4eb0aa2651454c1b1be7db86ef811c41ab68复用实际精确字节，未虚称所有已存在组件重新转换。

3: 环境。两套独立Python3.11.17。基础torch2.3.1/numpy1.26.4/coremltools9.0，实际resolved scipy1.17.1（基础历史requirements未单独冻结scipy，不声称其历史版本相同）；enumerated/量化torch2.7.0/numpy1.26.4/scipy1.13.1/coremltools9.0。protobuf4.25.0、onnx1.16.0、safetensors0.8.0，完整material deps和脚本SHA见freeze/source-binding。全部在本地macOS和USB iPhone执行，非Colab/Drive。

4: 配方与host gate。Current固定基础参考重建PASS，Current LLM224 prefill+64 teacher-forced decode logits/hidden/48-state逐项exact0；仅conversion_date metadata日期变化明确分离，不放宽数值条件。新四multifunction families n001_128/n129_256/n257_384/n385_450覆盖自然N1...450，不padding/crop。P2只按原数学repack两组，N1/128/129/260/385/450与六分片velocity均bit-identical maxAbs0。Current static/host PASS后才做量化。Q8为169 linear.weight、int8/linear_symmetric/per_channel/threshold2048；Hybrid为同一新Q8 prefill +169矩阵int4/per_channel rescue-A decode，FP16 IO/state、48-state request bridge。量化64步数值特征逐项复现历史对应Q8/rescue-A；不是宣称量化与Current全数值相等。Full-Q4 prefill未构建/运行/发布/暴露。

5: 新不可变身份。以下完整SHA也在NEW_ASSET_INVENTORY.json，带全文件bytes/hash、package尺寸和P2：

current: manifest=2ddc7fa084fb0e458b34f61af7fcc927773fb3697496a17f8ae1593ba33b56ee；payload/tree=dbea074bfc8dc49514c32d99f38f378d6ed030cd60b25d82f807b2dd69b40677；prefill=62f5a760f1a23dcf8540627fa2e7f52c9d0dd912e0094b90fec642b6b5801ece；decode=c466ebefec84a4e05da001675bd4e4901c23459964064c9819dca6ccb5eb1c37；runtime bytes=3530215890。

q8: manifest=a276c672e178b4e87d44be96dcb24453bb45b76366270299b5977eca732dc2b5；payload/tree=14fbec1f7765e1f5569200a67cb5d14b4f9758c9b56bc1c9e5363e10c5019c05；prefill=3cea2eae34b390a14e3bb79f5f4c97353ea22ec8a723ab01e9767156bd528a18；decode=46c52f10b28f947509e6c35bad05c4c942076b39d8b62d791cb4c0d8e093076d；runtime bytes=2803735289。

hybrid_q4: manifest=4f8e3aec18152c07a0e31814c2fa9ac92c3555fc4345f22f378cc07c6aa495d8；payload/tree=0cd48a4704f12485cfa8f863ae9996ed5f8908e19dbbdd3540fe91e711a81fbe；prefill=3cea2eae34b390a14e3bb79f5f4c97353ea22ec8a723ab01e9767156bd528a18；decode=d3e7135201e0e8c7a3f5a6282ba8d42abab95504c8c819a3441aa20c113963e1；runtime bytes=2621792999。

P2 shared: group-0.mlpackage=70dd09f89694af1774832cd451cdbce8585f16128e9762fc5bb82d653fa54287; group-1.mlpackage=24c3039d6d59a7b88e5cc9d4334e99ef8b7a0cd7ba13ec493e70781dcf24b408。

6: 新物理与human证据。iPhone Air/iPhone18,4/00008150-000A05CA1440401C/iOS27.2(24B5089g)，CoreML CONNECTED，签名Release。独立revalidation source be0e613dfdf09208573d5626579050ed81fe6fcc(Current首轮)及5d3371b022865ab255195ab9f624caed94aa9c31(all-profiles/fresh trace)。每profile五次冻结workload/seed42/SHARDS2/Flow6/public synthesize，token/PCM重复确定，referenceWAV/transcript不变。Current六段新token/PCM/WAV与此前人工认可语料完全一致；Q8三段、Hybrid三段亦完全一致，包括已认可Hybrid446-token/MAX_LENGTH长句。因此human PASS仅按文档允许的精确已认可输出等价性继承，未因“同配方”自动通过、未声称新任意文本均经人工试听。physical目录有独立新receipt与equivalence hashes。

7: 新ANE拓扑。官方Time Profiler+Core ML+Points of Interest+Neural Engine新trace，各profile5 prefill、1295 decode硬件prediction完整匹配新packageSHA、实际process-load事件、原生PID/stage containment；LLM coarse CPU activity0，prediction activity topology未增加碎片。Current cached load6 vs旧5为prepare/warm额外一次constructor，prediction计数/containment未放宽。原始失败Core AI保存、缺instrument与boot-timeout尝试均保留。Acoustic仍是CPU/GPU混合执行。实际per-operation residency UNKNOWN，不声称100% ANE。

8: 内存/性能范围。以下为新无profiler五次revalidation receipt，warm四次；采样peak包含所记录的阶段/诊断范围，并非连续精确峰值。USB/charging、cache/thermal条件不构成正式配对head-to-head，CPU-only Recount不是ANE/GPU或整机能耗：

current: warmRTF=[0.4959476882692308, 0.49086455134615387, 0.49151008413461544, 0.49162618586538454]；median=0.491568135；mean=0.492487127；min=0.490864551；max=0.495947688；sampledPeakBytes=2326596768；整体receipt thermal=nominal->serious。completion/idle/request CPU-only energy及各stage timing在完整physical receipt中。

q8: warmRTF=[0.3910744751923077, 0.38598571711538465, 0.3875774278846154, 0.386887744326923]；median=0.387232586；mean=0.387881341；min=0.385985717；max=0.391074475；sampledPeakBytes=1610189936；整体receipt thermal=nominal->fair。completion/idle/request CPU-only energy及各stage timing在完整physical receipt中。

hybrid_q4: warmRTF=[0.28468908653846153, 0.28163050076923074, 0.2858124599038462, 0.2854860817307693]；median=0.285087584；mean=0.284404532；min=0.281630501；max=0.285812460；sampledPeakBytes=1424116920；整体receipt thermal=nominal->fair。completion/idle/request CPU-only energy及各stage timing在完整physical receipt中。

9: HF发布。actacomes/CosyVoice-assets，private；新version0.3.1-rc1，revision c16f38383fa261bfed317fbec2fad2c4115d690c，tag ios-weight-profiles-current-q8-q4hybrid-v0.3.1-rc1，prefix ios-weight-profiles-current-q8-q4hybrid/0.3.1-rc1。Collection content tree47958326989cca9ad26fe3001b03d858c205cdfa19bd5f60d19b40e16f6e54a1；三逻辑目录current/q8/hybrid_q4、共享P2。全204文件在新的remote目录重新下载，bytes/SHA/tree与冻结inventory全一致；Runner公共fetch入口又从精确revision请求并逐文件校验同一远端下载cache，未用local build作为remote证明。没有Full-Q4、失败block32、checkpoint、conversion caches、trace或试听WAV上传。

10: SDK/API。pushed immutable source branch codex/cosyvoice-rebuilt-profiles-20261006@6eb42045a61015b000e40b88d6a9da0a126efce8。public selector .current/.q8/.hybridQ4；.q4代码调用保留兼容，canonical raw ID为hybrid_q4。Current缺省，schema3 collection/default初始化自动严格P2，legacy schema1/2原路由保留。SDK私有映射并strict验证manifest/root/package/P2，新metadata包含high-level HF revision/collection/profile-tree/LLM/P2/stateBridgeMode。wrong/mixed assets拒绝，无fallback。Swift6 74tests/5skipped/0fail；metadata-only/model-fixture skip不是神经或物理通过依据。

11: Demo架构。实际main c01e268基线，仍一个CosyVoice3Core/同一CosyVoice3CloneBackend，沿用三个benchmark profile出口；普通四engine registry保留，其他三SDK远端cleanhouse及链接均PASS。engine=cosyvoice，profile=current/q8/hybrid_q4，缺省Current；旧cosyvoice3/q4等配置兼容，未知profile在host和nativeautomation均拒绝，避免nil转Run All。新增COSYVOICE_ASSETS.json精确pin与generic fetch verifier，无torch/coremltools/private模型映射/转换。receipt canonical engineID cosyvoice +独立weightProfileID，保留benchmarkProviderID，source/HF/profile-tree/manifest/prefill/decode/P2/bridge/SHARDS/Flow/device/placement均绑定。SDK-derived资产身份不会被可选旧config字段覆盖。

12: 构建/测试。Demo actual Swift Configuration编译解码与guard测试、mixed/extra/wrong manifest真实verifier tests、六出口/多引擎/stage contracts均PASS。四SDK全链接签名Release BUILD SUCCEEDED，strict codesign PASS；binary SHA见demo-signed-build-receipt.json。Demo编译前文件SHA/dirty main基线/remoteSDK来源已捕获，未把后来生成的Git commit冒称原设备binary source。Synthesis既有metrics与debug保留。现有Sustained Playback lane经同一public profile backend接入；未运行最终长测试。

13: 三个短Runner physical smoke。204文件远端collection stage9,620,427,127 bytes，host generic stage-tree a6c664d1b86269e8ed81a74692532d2068ee28d94aa59191f7d88ee7677edf8b（tab-delimited stage算法含collection manifest，与SDK null-delimited profile/content tree不同，不能混同）。设备实际verify/install PASS；每profile在--terminate-existing的新进程执行同一reference/短文本。Current配置特意没有profile，实际current/P2/Flow6 PASS。三份receipt新SDK source/HF/LLM/P2等逐字段一致，actual exported WAV均Float32/mono/24kHz/153600samples且全部有限。Q8/Hybrid observed devicePID6465/6468；Current只有命令/独立本次receipt证据，不补造未采到的PID。旧Omni receipt按timestamp拒绝。正常unseeded public synthesize，非用于重现seed42语料/质量/RTF排名；no playback，no long benchmark。Actual WAV与console位于本地rebuild-20261006/runner-smoke，文件SHA在smoke-gate，未上传成模型资产。公开bridge无需state/shard CLI。

14: 历史失败和限制。保留所有初始source/metadata gate失败、staging/export-receipt缺失、collector cwd Git失败、Instruments保存/缺table/boot timeout。最终PASS只取修复后的完整receipt，partial Q8失败receipt没有改成PASS。没有将host/build、MLComputePlan偏好或requested CPU_AND_NE称作物理/100%ANE。当前APP短smoke没有再声明per-op实际设备，fresh revalidation trace只适用于其明确source/models/PID范围。

15: 最终问题逐项回答。

1: 缺失必需runtime模型已按权威出处重建；已有冻结共享组件按精确原字节复用并记录，不虚称其重新生成。
2: Current复现历史accepted token/PCM/WAV和host语义；模型包新身份独立。
3: Q8复现全部三段原human-approved token/PCM/WAV，无需新human请求。
4: Hybrid复现全部三段原human-approved输出，包含长MAX_LENGTH句，无需新human请求。
5: 新完整SHA见本报告第5项及NEW_ASSET_INVENTORY.json，manifest相同处如实保留实际hash。
6: Current/Q8/Hybrid新 signed Release public synthesis五次、fixed listening corpus、新hash绑定trace均PASS。
7: 必需human gates按精确approved-output equivalence PASS；不涵盖未试听的新任意文本。
8: 新immutable HF revision已发布c16f38383fa261bfed317fbec2fad2c4115d690c。
9: exact revision独立clean重下载204文件SHA验证PASS。
10: Runner用该精确remote revision及同一runtime bytes，无conversion。
11: Current仍default，host/native/default SDK和缺省profile物理smoke均验证。
12: Full-Q4 prefill排除，未生成/发布/Benchmark/暴露。
13: formal automation以--terminate-existing一profile一fresh process；同时使用同一immutable模型bytes，clean-room不是重转换。
14: 三个short Runner smoke均PASS，真实WAV有限、完整身份正确。
15: 后续whole-device head-to-head仍需明确开启长测试、Release/unplugged/not charging/wireless host control、匹配battery/nominal thermal/cache、fixed screen policy、Power Profiler和完整播放drain/实际played-audio分母。process CPU-only不是整机能耗。当前scope不执行该比较；per-op residency仍UNKNOWN。若后续需要deterministic Runner seed，必须另验证public SDK实际seed应用，当前只把通用VOICE_BENCHMARK_SEED记作requested，短smoke没有设定它。

GitHub Timeline: SDK source6eb42045a61015b000e40b88d6a9da0a126efce8 PUSHED on frozen source branch; SDK evidencee975e6d3581240ee6a1789b9ea691b3359ff51b7 and Demo integrationed4ed85de43bb68b6b9e5877e13e6a537371f124 PUSHED on independent branches. Main unchanged/unmerged. Final timeline-only commit does not change tested runtime/model bytes. Physical source5d3371b remains COMMITTED_NOT_PUSHED in preserved independent checkout. See GIT_TIMELINE.json. Original missing-byte audit hashes unchanged.
