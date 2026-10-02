#@title smoke_rebuild_python_imports.py
# Requirement: fail before any multi-GB checkpoint download unless the isolated rebuild Python environment can import the exact Matcha/CosyVoice modules needed by HyperPyYAML without resolving into a developer-local environment.
from __future__ import annotations
import argparse,importlib,json,sys
from pathlib import Path

FORBIDDEN="/Volumes/WD/Codes/CosyVoice3/.venv-upstream"

def module_file(name:str)->str:
    module=importlib.import_module(name)
    return str(getattr(module,"__file__",""))

def main():
    p=argparse.ArgumentParser(); p.add_argument("--source-root",type=Path,required=True); a=p.parse_args()
    source=a.source_root.resolve()
    sys.path[:0]=[str(source/"iOS/tools"),str(source),str(source/"third_party/Matcha-TTS")]
    names=["coremltools","torch","transformers","hyperpyyaml","diffusers","PIL","conformer","matcha.utils","matcha.utils.pylogger","matcha.models.components.decoder","matcha.models.components.transformer","matcha.models.components.flow_matching","matcha.hifigan.xutils","matcha.hifigan.models","cosyvoice.flow.flow_matching","cosyvoice.flow.DiT.dit","cosyvoice.hifigan.hifigan","cosyvoice.hifigan.generator"]
    resolved={name:module_file(name) for name in names}
    bad={name:path for name,path in resolved.items() if FORBIDDEN in path}
    bad_path=[entry for entry in sys.path if FORBIDDEN in str(entry)]
    if bad or bad_path: raise RuntimeError(f"developer-local Python environment leaked into rebuild imports: modules={bad} sys.path={bad_path}")
    receipt={"schemaVersion":1,"status":"PASS_REBUILD_IMPORT_SMOKE","python":sys.executable,"sourceRoot":str(source),"modules":resolved}
    print("[COSYVOICE3-REBUILD-IMPORTS] PASS "+json.dumps(receipt,sort_keys=True),flush=True)

if __name__=="__main__": main()

# Code purpose: detect incomplete or contaminated rebuild dependencies before checkpoint download or Core ML conversion begins.
# Upstream source: locked CosyVoice3_NPU source and Matcha-TTS submodule import graph.
# Runtime environment: isolated Python 3.11 rebuild venv.
# Generated: 2026-10-02 America/New_York.
# Changes: validates conformer/diffusers/Pillow/Matcha/CosyVoice conversion imports and rejects the historical developer-local Python 3.10 path.
# Changes 2026-10-02: explicitly smoke sanitized matcha.utils/pylogger and no longer require Lightning/Hydra, which are training-only for this conversion path.
# Changes 2026-10-02: extend preflight through Matcha HiFiGAN xutils/models and CosyVoice HiFiGAN wrapper/generator so plotting-only eager dependencies are caught before model fixture construction.
