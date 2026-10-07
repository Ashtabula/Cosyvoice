# Rebuilt Current/Q8/Hybrid Q4 profile checklist

更新2026-10-06 23:14 EDT，执行位置本地 Mac + USB iPhone Air；历史失败报告保留。以下 PASS 均限定在本次证据范围，不能解释为最终 production promotion 或 unplugged 整机 benchmark。

## Current

1: provenance: PASS.

2: environment pinned: PASS.

3: conversion: PASS.

4: manifest/tree/package/P2 integrity: PASS.

5: host IO/state/finite/parity: PASS.

6: signed Release physical public synthesis ×5: PASS.

7: deterministic frozen token/PCM output: PASS.

8: memory receipts: PASS.

9: bounded timing receipts: PASS.

10: new ANE topology: PASS.

11: human listening: PASS: exact approved token/PCM/WAV equivalence, limited corpus.

12: wrong/mixed asset fail-closed: PASS: new identity-bound Swift tests.

13: Swift6: PASS: 73 tests,5 skipped,0 failures.

14: signed revalidation Release build/signature (source5d3371b): PASS.

15: publish readiness: PASS: private HF revision published and clean204 hashes verified.

16: final sustained/unplugged energy/thermal: N/A: explicitly excluded.

## Q8

1: provenance: PASS.

2: environment pinned: PASS.

3: conversion: PASS.

4: manifest/tree/package/P2 integrity: PASS.

5: host IO/state/finite/parity: PASS.

6: signed Release physical public synthesis ×5: PASS.

7: deterministic frozen token/PCM output: PASS.

8: memory receipts: PASS.

9: bounded timing receipts: PASS.

10: new ANE topology: PASS.

11: human listening: PASS: exact approved token/PCM/WAV equivalence, limited corpus.

12: wrong/mixed asset fail-closed: PASS: new identity-bound Swift tests.

13: Swift6: PASS: 73 tests,5 skipped,0 failures.

14: signed revalidation Release build/signature (source5d3371b): PASS.

15: publish readiness: PASS: private HF revision published and clean204 hashes verified.

16: final sustained/unplugged energy/thermal: N/A: explicitly excluded.

## Hybrid Q4 — Q8 Prefill + Q4 Decode

1: provenance: PASS.

2: environment pinned: PASS.

3: conversion: PASS.

4: manifest/tree/package/P2 integrity: PASS.

5: host IO/state/finite/parity: PASS.

6: signed Release physical public synthesis ×5: PASS.

7: deterministic frozen token/PCM output: PASS.

8: memory receipts: PASS.

9: bounded timing receipts: PASS.

10: new ANE topology: PASS.

11: human listening: PASS: exact approved token/PCM/WAV equivalence, limited corpus.

12: wrong/mixed asset fail-closed: PASS: new identity-bound Swift tests.

13: Swift6: PASS: 73 tests,5 skipped,0 failures.

14: signed revalidation Release build/signature (source5d3371b): PASS.

15: publish readiness: PASS: private HF revision published and clean204 hashes verified.

16: final sustained/unplugged energy/thermal: N/A: explicitly excluded.

ANE PASS means exact new model hash/actual load + PID/native stage containment + prediction-event topology with no coarse LLM CPU activity; actual per-operation residency remains UNKNOWN. Acoustic pipeline retains CPU/GPU mixed activity. Historical HUMAN_PASS is inherited only through new actual WAV/PCM/token exact equivalence receipts.

SDK final metadata/default changes: 74 Swift6 tests,5 skipped,0fail. Signed integrated Demo Release and short Runner smoke still pending; keep them distinct from source5d3371b revalidation app.

Final integration gate2026-10-06 23:29 EDT: signed four-SDK Demo Release PASS, exactnewHF fetch/stage PASS, allthree shortphysical Runner smokes PASS. Long unplugged thermal/whole-device test N/A excluded. SDK74/5skip/0fail, productionSwift config guard/default/aliases and real mixed-byte verifier PASS.
