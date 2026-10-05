CosyVoice3 结果 — 2026-10-05T08:54:44.843198-04:00

结论：RTF < 1 未达成；拒绝速度优化 promotion。物理 tested SHA 766e735；最终 source SHA 866e89f（新增拒绝 GPU 对照，默认路径未变；未在该 SHA 重跑设备）。



1: 同一611字、16段文本，冻结 dynamic N1...479 asset；每轮独立 nominal 启动、Release、关闭播放。实际生成长度不同；SystemRandomNumberGenerator 未响应 seed42，未改变 sampling。

2: cosy-baseline：RTF 2.870326，音频 240.36s，峰值 3062.64MiB，结束 644.89MiB，能耗 3.801438J/audio-s，thermal nominal→serious→serious。分项/nested Flow 见 JSON，不能重复相加。

3: cosy-candidate：RTF 3.109059，音频 234.48s，峰值 3101.83MiB，结束 431.81MiB，能耗 3.394624J/audio-s，thermal nominal→serious→serious。分项/nested Flow 见 JSON，不能重复相加。

4: cosy-fast-hint：RTF 3.099898，音频 241.56s，峰值 3097.68MiB，结束 437.05MiB，能耗 3.211997J/audio-s，thermal nominal→serious→serious。分项/nested Flow 见 JSON，不能重复相加。

5: baseline 分项：reference8.551s、LLM182.920s、acoustic model load77.069s、acoustic execute420.549s，其中Flow400.880s、F0 .939s、decoder18.217s。Flow 是主要瓶颈；编译/特化仅包含在 constructor/first prediction，未获得独立 compiler 计时。

6: provider 复用通过真实 CoreML 128步 logits maxAbs=0；default Release47测试、4项跳过、无失败。Flow fastPrediction host N186/N225 PCM maxAbs=0，但整机RTF3.099898与默认3.109059差异不足以证明速度收益。

7: CPU_AND_GPU acoustic host 对照 N186 maxAbs1.695045，N225 maxAbs1.275717，已拒绝且未做物理GPU benchmark。LLM/reference仍CPU_ONLY；默认 acoustic CPU_AND_NE，6 steps，模型 bytes 未变。

8: 人类听审仍 PENDING，绑定 766e735 默认候选234.48秒 WAV，不借用旧 Omni/Vox 听审。各轮16/16 finite/nonempty/完整 WAV 导出；这些机器检查不是听审。

9: 能耗下降、结束 footprint 较低均为单轮观测，未达到因果优化证明；nominal 起点不足以消除 thermal/stochastic/cache差异。历史 fixed225 RTF<1 属于不同 asset，不混作当前 dynamic-route 对照。

10: 工作在本地仓库和物理iPhone；源代码已 push 到 experiment/ios-dynamic-acoustic，main 未合并。完整日志/失败实验/资源收据保留于同目录；停止状态与最终 evidence commit SHA 见 completion.json。
