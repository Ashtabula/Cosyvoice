# CosyVoice3 iOS benchmark status

Current benchmark evidence belongs to the development harness, not yet to the standalone public SDK.

The development repository contains physical-device Core ML experiments for stateful LLM, sharded Flow, full frozen pipeline and Instruct2 native generation. The full-pipeline benchmark explicitly replays prepared inputs and is not raw text/reference frontend -> public API -> PCM validation.

The 8789402 audit rechecked existing Instruct2 receipts for happy, angry, fast, soft and Sichuan controls. Accepted native host/device sequences terminate with actual EOS 6562; the audit changed terminology only and ran no new performance or audio experiment.

Candidate benchmark evidence must be produced after the public engine exists. Record publication/source commit, immutable asset identity, physical iPhone/OS, workload, cold startup, warm repeated synthesis, output sample rate/channels/duration, and preserved receipt. Do not describe Core ML execution as proven ANE residency without independent placement evidence.
