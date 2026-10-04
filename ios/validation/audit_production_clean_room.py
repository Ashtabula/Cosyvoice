#!/usr/bin/env python3
#@title audit_production_clean_room.py
# Requirement: ensure the Production clean-room app consumes CosyVoice3 only through the stable public SDK and contains no validation SPI or private runtime/source dependency.
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]; SRC=ROOT/"validation/ProductionCleanRoom/CosyVoice3ProductionCleanRoom/CosyVoice3ProductionCleanRoomApp.swift"; PROJECT=ROOT/"validation/ProductionCleanRoom/CosyVoice3ProductionCleanRoom.xcodeproj/project.pbxproj"
text=SRC.read_text(); project=PROJECT.read_text()
for token in ("@_spi","CosyVoice3AcousticRuntime","CosyVoice3Stage1Runtime","CosyVoice3LLMRuntime","CosyVoice3AssetLoader","NPU_engines_Demo","NPU_bookreader","CosyVoice3_NPU"):
    if token in text: raise RuntimeError(f"clean-room app contains private dependency marker: {token}")
for required in ("import CosyVoice3Core","CosyVoice3Engine(assetRoot:","engine.synthesize(binding.workloadText","CosyVoice3Parameters(","flowSteps:.steps6"):
    if required not in text: raise RuntimeError(f"clean-room public API marker missing: {required}")
if "XCLocalSwiftPackageReference" not in project or "CosyVoice3Core" not in project: raise RuntimeError("clean-room project is not linked through Swift package product")
print("[COSYVOICE3-PRODUCTION-CLEAN-ROOM-AUDIT] PASS publicApiOnly=true",flush=True)
# Code purpose: static independent-consumer boundary gate for the Production clean-room host.
# Runtime environment: Python 3 standard library.
# Generated time: 2026-10-03 America/New_York.

# Changes 2026-10-03: match the intentionally compact Swift call syntax used by the clean-room consumer while still requiring the public .steps6 parameter.

# Changes 2026-10-03: require the clean-room consumer to synthesize the staged Candidate-frozen workload rather than a newly invented literal sentence.
