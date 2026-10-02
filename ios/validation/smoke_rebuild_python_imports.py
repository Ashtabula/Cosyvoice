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
    names=["coremltools","torch","transformers","hyperpyyaml","diffusers","PIL","conformer","matcha.utils","matcha.utils.pylogger","matcha.models.components.decoder","matcha.models.components.transformer","matcha.models.components.flow_matching","cosyvoice.flow.flow","cosyvoice.flow.flow_matching","cosyvoice.flow.DiT.dit","cosyvoice.transformer.upsample_encoder","cosyvoice.hifigan.generator","cosyvoice.hifigan.f0_predictor","export_llm_mask_write512"]
    resolved={name:module_file(name) for name in names}
    bad={name:path for name,path in resolved.items() if FORBIDDEN in path}
    bad_path=[entry for entry in sys.path if FORBIDDEN in str(entry)]
    if bad or bad_path: raise RuntimeError(f"developer-local Python environment leaked into rebuild imports: modules={bad} sys.path={bad_path}")
    from google.protobuf import __version__ as protobuf_version
    from google.protobuf import descriptor_pb2
    maskwrite=importlib.import_module("export_llm_mask_write512")
    repeated_field=descriptor_pb2.FileDescriptorProto.DESCRIPTOR.fields_by_name["dependency"]
    scalar_field=descriptor_pb2.FileDescriptorProto.DESCRIPTOR.fields_by_name["name"]
    if maskwrite.field_is_repeated(repeated_field) is not True: raise RuntimeError("maskwrite512 protobuf compatibility helper rejected a repeated field")
    if maskwrite.field_is_repeated(scalar_field) is not False: raise RuntimeError("maskwrite512 protobuf compatibility helper misclassified a scalar field")
    receipt={"schemaVersion":2,"status":"PASS_REBUILD_IMPORT_SMOKE","python":sys.executable,"sourceRoot":str(source),"modules":resolved,"protobufVersion":protobuf_version,"maskwrite512DescriptorCompatibility":"PASS"}
    print("[COSYVOICE3-REBUILD-IMPORTS] PASS "+json.dumps(receipt,sort_keys=True),flush=True)

if __name__=="__main__": main()

# Code purpose: detect incomplete or contaminated rebuild dependencies before checkpoint download or Core ML conversion begins.
# Upstream source: locked CosyVoice3_NPU source and Matcha-TTS submodule import graph.
# Runtime environment: isolated Python 3.11 rebuild venv.
# Generated: 2026-10-02 America/New_York.
# Changes: validates conformer/diffusers/Pillow/Matcha/CosyVoice conversion imports and rejects the historical developer-local Python 3.10 path.
# Changes 2026-10-02: explicitly smoke sanitized matcha.utils/pylogger and no longer require Lightning/Hydra, which are training-only for this conversion path.
# Changes 2026-10-02: preflight the exact Flow/HiFT-only module closure used by the derived acoustic config; GAN wrapper/discriminator and dataset/training modules are intentionally excluded.
# Changes 2026-10-02: import the sanitized maskwrite512 exporter and exercise its repeated/scalar descriptor helper against the installed protobuf runtime before any multi-hundred-MB LLM export.
