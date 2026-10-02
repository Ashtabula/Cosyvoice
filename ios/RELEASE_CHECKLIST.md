# CosyVoice3 iOS release checklist

Current status: Development.

PASS: publication target is `Ashtabula/Cosyvoice/ios/`.
PASS: source is locked to `Ashtabula/CosyVoice3_NPU@878940245562bcd1dd0231d78157ba78d70b39f6`.
PASS: standalone `Package.swift`, reusable runtime `Sources/`, and Stage1 runtime `Tests/` are present.
PASS: the 8789402 EOS/stop-token semantic audit is preserved.
PASS: benchmark application source was not copied into `Sources/`.
PASS: accelerator status remains not-claimed.

BLOCKER: no callable end-to-end `CosyVoice3Engine` facade exists.
BLOCKER: low-level Stage1 runtime types are still public; after facade extraction, implementation-only types should become internal where possible.
BLOCKER: raw text/reference frontend and enrollment are not integrated into `Sources/`.
BLOCKER: native LLM/RAS, Flow and HiFT production path remains primarily in the development harness.
BLOCKER: canonical asset list, immutable fetcher, fail-closed validator and hosted manifest do not exist.
BLOCKER: one-command pinned local rebuild does not exist.
BLOCKER: no physical-device smoke starts from this publication tree and uses only the public API for real text/reference -> PCM.
BLOCKER: no Candidate `validation/release_receipt.json` ties build, assets, parity, device, PCM and benchmark evidence to this publication commit.
BLOCKER: clean-room integration has not run.
BLOCKER: model/runtime redistribution license review remains incomplete.

Do not label Candidate until all Candidate blockers have committed evidence. Do not label Production until audio review, clean-room integration, release-tree reproducibility and license review also pass.
