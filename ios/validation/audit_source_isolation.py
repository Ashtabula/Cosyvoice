#@title audit_source_isolation.py
# Requirement: fail closed when shipping iOS runtime source depends on migration/demo/product repositories, developer-specific paths, Python runtime launching, or non-Swift runtime files.
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]; SRC=ROOT/"Sources"; forbidden=("CosyVoice3_NPU","NPU_engines_Demo","NPU_bookreader","StatefulLLMBench","/Volumes/","/Users/","Process(","python3","python ")
if not SRC.is_dir(): raise RuntimeError(f"missing runtime source directory: {SRC}")
files=sorted(p for p in SRC.rglob("*") if p.is_file())
bad=[]
for p in files:
    if p.suffix!=".swift": bad.append(f"{p.relative_to(ROOT)}: non-Swift shipping runtime file"); continue
    text=p.read_text(encoding="utf-8")
    for token in forbidden:
        if token in text: bad.append(f"{p.relative_to(ROOT)}: forbidden runtime dependency/path marker {token!r}")
if bad: raise RuntimeError("iOS source isolation failed:\n" + "\n".join(bad))
print(f"[COSYVOICE3-SOURCE-ISOLATION] PASS swiftFiles={len(files)} sourceRoot={SRC}",flush=True)
# Code purpose: enforce the canonical 检查单 source-isolation boundary on shipping iOS Sources only.
# Upstream source: Ashtabula/NPU_engines_Demo/SDK_RELEASE.md source-isolation gate.
# Runtime environment: Python 3 standard library in CI or release checkout; shipping runtime itself has no Python dependency.
# Generated time: 2026-10-03 America/New_York.
# Changed lines: new file; runtime-only static dependency/path audit.
