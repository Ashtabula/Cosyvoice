#@title sanitize_rebuild_source.py
# Requirement: make the pinned temporary rebuild checkout hermetic and conversion-only, after exact Git blob verification, without changing model math.
from __future__ import annotations
import argparse,hashlib,json,subprocess
from pathlib import Path

SOURCE_COMMIT="878940245562bcd1dd0231d78157ba78d70b39f6"
MATCHA_COMMIT="dd9105b34bf2be2230f4aa1e4769fb586a3c824e"
ACOUSTICS=Path("iOS/tools/export_pipeline_acoustics.py")
ACOUSTICS_BLOB="2e0eb4dc5d9216db07207e5564f13a38c4ad2e74"
MATCHA_UTILS=Path("matcha/utils/__init__.py")
MATCHA_UTILS_BLOB="074db6461184e8cbb86d977cb41d9ebd918e958a"
MATCHA_PYLOGGER=Path("matcha/utils/pylogger.py")
MATCHA_PYLOGGER_BLOB="61600678029362e110f655edb91d5f3bc5b1cd1c"
MASKWRITE512=Path("iOS/tools/export_llm_mask_write512.py")
MASKWRITE512_BLOB="26be8d181bf0886282a372ea8627ac37e0c15a65"
FORBIDDEN="sys.path.append('/Volumes/WD/Codes/CosyVoice3/.venv-upstream/lib/python3.10/site-packages')"
FULL_CONFIG="MODEL/'cosyvoice3.yaml'"
ACOUSTIC_CONFIG="MODEL/'cosyvoice3.acoustic.yaml'"
ACOUSTIC_LOAD_WITH_QWEN_OVERRIDE="load_hyperpyyaml(f,overrides={'qwen_pretrain_path':str(MODEL/'CosyVoice-BlankEN')})"
ACOUSTIC_LOAD="load_hyperpyyaml(f)"
UTILS_REPLACEMENT="from matcha.utils.pylogger import get_pylogger\n"
PYLOGGER_REPLACEMENT="""import logging

def get_pylogger(name: str = __name__) -> logging.Logger:
    return logging.getLogger(name)
"""
MASKWRITE_HELPER="""def field_is_repeated(field):
    value = getattr(field, 'is_repeated', None)
    if value is not None:
        return bool(value)
    return field.label == field.LABEL_REPEATED


"""

def sha256(path:Path)->str:
    h=hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda:f.read(1024*1024),b""): h.update(block)
    return h.hexdigest()

def git_blob(repo:Path,relative:Path)->str:
    return subprocess.check_output(["git","-C",str(repo),"rev-parse",f"HEAD:{relative.as_posix()}"],text=True).strip()

def patch_exact(path:Path,expected_blob:str,replacement:str,repo:Path,name:str)->dict:
    blob=git_blob(repo,path.relative_to(repo))
    if blob!=expected_blob: raise RuntimeError(f"unexpected {name} Git blob: {blob}")
    before=sha256(path); path.write_text(replacement); after=sha256(path)
    return {"name":name,"target":str(path.relative_to(repo)),"originalGitBlob":blob,"originalSha256":before,"sanitizedSha256":after}

def main():
    p=argparse.ArgumentParser(); p.add_argument("--source-root",type=Path,required=True); p.add_argument("--output",type=Path,required=True); a=p.parse_args()
    source=a.source_root.resolve(); output=a.output.resolve(); matcha=source/"third_party/Matcha-TTS"
    head=subprocess.check_output(["git","-C",str(source),"rev-parse","HEAD"],text=True).strip()
    if head!=SOURCE_COMMIT: raise RuntimeError(f"source HEAD mismatch: {head}")
    matcha_head=subprocess.check_output(["git","-C",str(matcha),"rev-parse","HEAD"],text=True).strip()
    if matcha_head!=MATCHA_COMMIT: raise RuntimeError(f"Matcha submodule HEAD mismatch: {matcha_head}")

    acoustics=source/ACOUSTICS
    if git_blob(source,ACOUSTICS)!=ACOUSTICS_BLOB: raise RuntimeError("unexpected upstream acoustics blob")
    text=acoustics.read_text()
    if text.count(FORBIDDEN)!=1: raise RuntimeError("expected exactly one developer-local sys.path escape hatch")
    if text.count(FULL_CONFIG)!=1: raise RuntimeError("expected exactly one full acoustic HyperPyYAML load")
    if text.count(ACOUSTIC_LOAD_WITH_QWEN_OVERRIDE)!=1: raise RuntimeError("expected exactly one legacy qwen_pretrain_path acoustic override")
    before=sha256(acoustics)
    text=text.replace(FORBIDDEN,"# release rebuild: developer-local Python site-packages path intentionally disabled")
    text=text.replace(FULL_CONFIG,ACOUSTIC_CONFIG)
    text=text.replace(ACOUSTIC_LOAD_WITH_QWEN_OVERRIDE,ACOUSTIC_LOAD)
    acoustics.write_text(text)
    after=sha256(acoustics)
    if "/Volumes/WD/Codes/CosyVoice3/.venv-upstream" in text or FULL_CONFIG in text or "qwen_pretrain_path" in text: raise RuntimeError("acoustic exporter sanitation incomplete")

    utils_patch=patch_exact(matcha/MATCHA_UTILS,MATCHA_UTILS_BLOB,UTILS_REPLACEMENT,matcha,"matcha-utils-init-training-imports")
    pylogger_patch=patch_exact(matcha/MATCHA_PYLOGGER,MATCHA_PYLOGGER_BLOB,PYLOGGER_REPLACEMENT,matcha,"matcha-pylogger-lightning-import")
    if "hydra" in (matcha/MATCHA_UTILS).read_text() or "lightning" in (matcha/MATCHA_PYLOGGER).read_text(): raise RuntimeError("training-only Matcha dependency remains")

    maskwrite=source/MASKWRITE512
    if git_blob(source,MASKWRITE512)!=MASKWRITE512_BLOB: raise RuntimeError("unexpected maskwrite512 exporter blob")
    mask_text=maskwrite.read_text()
    root_marker="ROOT = Path(__file__).resolve().parents[2]\n\n\n"
    if root_marker not in mask_text or mask_text.count("field.is_repeated")!=2: raise RuntimeError("unexpected maskwrite512 descriptor-access layout")
    mask_before=sha256(maskwrite)
    mask_text=mask_text.replace(root_marker,root_marker+MASKWRITE_HELPER,1).replace("field.is_repeated","field_is_repeated(field)")
    maskwrite.write_text(mask_text)
    mask_after=sha256(maskwrite)
    if "field.is_repeated" in mask_text or "def field_is_repeated(field):" not in mask_text: raise RuntimeError("maskwrite512 protobuf compatibility sanitation incomplete")
    mask_patch={"name":"maskwrite512-protobuf-repeated-field-compat","target":MASKWRITE512.as_posix(),"originalGitBlob":MASKWRITE512_BLOB,"originalSha256":mask_before,"sanitizedSha256":mask_after}

    acoustic_patch={"name":"acoustic-exporter-hermetic-config","target":ACOUSTICS.as_posix(),"originalGitBlob":ACOUSTICS_BLOB,"originalSha256":before,"sanitizedSha256":after}
    receipt={"schemaVersion":5,"status":"PASS_SOURCE_HYGIENE","sourceCommit":SOURCE_COMMIT,"matchaSubmoduleCommit":MATCHA_COMMIT,"target":ACOUSTICS.as_posix(),"originalGitBlob":ACOUSTICS_BLOB,"originalSha256":before,"sanitizedSha256":after,"acousticConfigRedirected":True,"acousticConfig":"cosyvoice3.acoustic.yaml","acousticQwenOverrideRemoved":True,"matchaUtilsTarget":MATCHA_UTILS.as_posix(),"matchaUtilsOriginalGitBlob":MATCHA_UTILS_BLOB,"matchaUtilsSanitizedSha256":utils_patch["sanitizedSha256"],"matchaPyloggerTarget":MATCHA_PYLOGGER.as_posix(),"matchaPyloggerOriginalGitBlob":MATCHA_PYLOGGER_BLOB,"matchaPyloggerSanitizedSha256":pylogger_patch["sanitizedSha256"],"maskwrite512Target":MASKWRITE512.as_posix(),"maskwrite512OriginalGitBlob":MASKWRITE512_BLOB,"maskwrite512SanitizedSha256":mask_after,"patches":[acoustic_patch,utils_patch,pylogger_patch,mask_patch],"changes":["disable one developer-local Python 3.10 site-packages append","redirect acoustic exporter from full checkpoint YAML to derived Flow+HiFT-only YAML","remove obsolete qwen_pretrain_path HyperPyYAML override because the acoustic-only graph contains no Qwen/LLM object","stop Matcha utils package from eagerly importing training/CLI utilities","replace Matcha distributed-training logger decoration with standard-library logging for conversion-only rebuild","replace protobuf-version-specific FieldDescriptor.is_repeated access with a compatibility helper that falls back to LABEL_REPEATED"],"runtimeMathChanged":False}
    output.parent.mkdir(parents=True,exist_ok=True); output.write_text(json.dumps(receipt,indent=2,sort_keys=True)+"\n"); print("[COSYVOICE3-REBUILD-HYGIENE] PASS "+json.dumps(receipt,sort_keys=True),flush=True)

if __name__=="__main__": main()

# Code purpose: keep the release rebuild hermetic and conversion-only without modifying model math or canonical development repositories.
# Upstream source: Ashtabula/CosyVoice3_NPU@878940245562bcd1dd0231d78157ba78d70b39f6 and Matcha-TTS@dd9105b34bf2be2230f4aa1e4769fb586a3c824e with exact Git blob guards.
# Runtime environment: Python 3 standard library inside the publication checkout.
# Generated: 2026-10-02 America/New_York.
# Changes: developer-local Python path removal, exact redirect to derived acoustic-only YAML with obsolete Qwen override removal, Matcha training-only eager-import cleanup, and exact-blob-gated protobuf descriptor compatibility for maskwrite512; no model equations, weights, State semantics, or tensor dimensions are changed.
