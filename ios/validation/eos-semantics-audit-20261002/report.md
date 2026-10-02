# CosyVoice3 EOS / stop-token 语义审计

时间：2026-10-02（America/New_York）。执行位置：本地 Git repository；旧模型目录只读。Phase4 已关闭。本次只审计源码与既有 receipt，不执行模型、性能、retention 或音频实验。

## 源码结论

1: 实际配置 `Fun-CosyVoice3-0.5B-2512/cosyvoice3.yaml:23–26` 使用 CosyVoice3LM，speech_token_size = 6561。只读 checkpoint metadata 确认 speech_embedding.weight 和 llm_decoder.weight 均为 [6761,896]。配置、源码 SHA-256 与模型实际路径见 audit.json。

2: `cosyvoice/llm/llm.py:679–703` 定义 SOS=6561、实际 EOS=6562、task_id=6563、fill_token=6564。speech token 范围是 0..6560；200 个 special/stop token 是 6561..6760（含两端）。这是有效 logits 域中所有 >=6561 的 ID，不是无限整数范围；6761 及更大不是有效输出。其他 special ID 的用途不能由这里推断。

3: CosyVoice3LM 继承 Qwen2LM，再继承 TransformerLM。`sampling_ids(ignore_eos=True)` 在 llm.py:150–161 只把 weighted_scores[self.speech_token_size] 设为 -Inf：对于 CosyVoice3，这恰好是 SOS6561，**不是实际 EOS6562**。它也不屏蔽整个 stop region。因此 min_len 前不保证实际 EOS6562 被禁止。保留这一上游行为，不擅自修正其历史参数名。

4: 非 vLLM `Qwen2LM.inference_wrapper`（llm.py:535–550）调用上述 sampling_ids，然后检查 `top_ids in self.stop_token_ids`；任何一个 special/stop token 都会在 yield、append 或下一步 embedding 前终止。vLLM 分支也使用 stop_token_ids，但其 min_tokens 由 vLLM 处理，不能将非 vLLM 单索引 mask 推论到 vLLM。本次 oracle/native 使用非 vLLM 路径。

5: `cosyvoice/utils/common.py:138–169` 的 ras_sampling 本身不决定 EOS、不屏蔽 special token、不负责停止。配置 pinned top_p=0.8、top_k=25、win_size=10、tau_r=0.1；native 使用原始 PyTorch RAS。五个 native receipt 的 RAS source hash 与当前源码一致。

6: native host 在 step<min_len 时只屏蔽 scores[6561]，之后选择 >=6561 即停止；在合法 6761 logits 域中与上游 stop region 等价。Swift 收到同一 special ID 后也停止，不将 terminal token 写入下一步 State。现有 225 decode cap 保留；它是既有诊断限制，与上游按文本推导的 max_len 不同，此次不修改。

7: receipt 文案“EOS6561 suppressed for exact upstream min_len”语义错误，已改为说明“只屏蔽 speech_token_size/SOS6561；CosyVoice3 EOS 为6562；stop IDs 为6561..6760”。兼容字段 `eos_token`、`eos_selection_index_zero_based`、状态 `COMPLETE_EOS` 和进度名 `eos_received` 保持原 schema；它们历史上代表 selected stop token，不能单凭字段名断言实际 EOS。

## 既有 native / oracle 证据

happy: native speech tokens=174，terminal=6562，zero-based selection index=174，context=53+174=227；oracle speech tokens=169。

angry: native speech tokens=164，terminal=6562，zero-based selection index=164，context=53+164=217；oracle speech tokens=174。

fast: native speech tokens=94，terminal=6562，zero-based selection index=94，context=56+94=150；oracle speech tokens=93。

soft: native speech tokens=219，terminal=6562，zero-based selection index=219，context=51+219=270；oracle speech tokens=227。

sichuan: native speech tokens=160，terminal=6562，zero-based selection index=160，context=50+160=210；oracle speech tokens=175。

五个 native host/device selected-token sequences 完全一致；最后一个 token 均为实际 EOS6562，之前全部为 speech IDs。计数、终止 index、最终 context 均一致。这里只核查已有 receipt，不新增 State 或音频质量结论。

Oracle capture 循环读取上游 inference generator。上游在 yield 前丢弃 stop token，所以现有 oracle receipts 未保存终止 ID；不能声称 oracle 也被证明终止于6562。Oracle speech token 文件 hashes 已核验。

## 修改、验证与边界

仅修改两个 Python 工具和 Swift runner 的注释，以及 native host receipt 的描述字符串。Python AST 在排除这一个描述字符串后与 HEAD 一致；Swift 排除新增整行注释后与 HEAD 一致。sampling、min_len、stop predicate、State、模型和输出 schema 都未修改。

9 份历史 host receipts 的语义修正副本放在 corrected-receipts/；原始 receipt 不动。corrections-and-validation.json 保存原始/副本 hashes、唯一变化字段，以及原始失败或完成状态。没有改变历史 numerical、promotion 或 audio acceptance 结论。

静态验证：源码交叉检查；checkpoint metadata 只读核查；五组 host/device/oracle receipt 与 token hash 核查；原始 receipt hashes 与修正副本单字段差异核查；Python AST / Swift comment-only 检查；git diff --check。结果：PASS_SEMANTIC_AUDIT_NO_BEHAVIOR_CHANGE。

不执行新的 native generation、音频、性能、Flow、retention、SDK 或量化实验。GitHub 状态：本次只提交 semantic audit，不 push；commit hash 由 Git 提交记录提供。
