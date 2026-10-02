#@title sanitize_rebuild_source.py
# Requirement: make the pinned temporary rebuild checkout hermetic by removing developer-local Python paths and Matcha training-only eager imports, only after exact Git blob verification; never change model math.
from __future__ import annotations
import argparse,hashlib,json,subprocess
from pathlib import Path

SOURCE_COMMIT="878940245562bcd1dd0231d78157ba78d70b39f6"
MATCHA_COMMIT="dd9105b34bf2be2230f4aa1e4769fb586a3c824e"
ACOUSTICS=Path("iOS/tools/export_pipeline_acoustics.py")
ACOUSTICS_BLOB="2e0eb4dc5d9216db07207e5564f13a38c4ad2e74"
MATCHA_UTILS=Path("third_party/Matcha-TTS/matcha/utils/__init__.py")
MATCHA_UTILS_BLOB="074db6461184e8cbb86d977cb41d9ebd918e958a"
MATCHA_PYLOGGER=Path("third_party/Matcha-TTS/matcha/utils/pylogger.py")
MATCHA_PYLOGGER_BLOB="61600678029362e110f655edb91d5f3bc5b1cd1c"
FORBIDDEN="sys.path.append('/Volumes/WD/Codes/CosyVoice3/.venv-upstream/lib/python3.10/site-packages')"
UTILS_REPLACEMENT="from matcha.utils.pylogger import get_pylogger\n"
PYLOGGER_REPLACEMENT="""import logging\n\ndef get_pylogger(name: str = __name__) -> logging.Logger:\n    return logging.getLogger(name)\n"""

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
    return {"name":name,"target":str(path),"originalGitBlob":blob,"originalSha256":before,"sanitizedSha256":after}

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
    acoustics_before=sha256(acoustics); acoustics.write_text(text.replace(FORBIDDEN,"# release rebuild: developer-local Python site-packages path intentionally disabled")); acoustics_after=sha256(acoustics)
    if "/Volumes/WD/Codes/CosyVoice3/.venv-upstream" in acoustics.read_text(): raise RuntimeError("developer-local upstream venv path remains after sanitation")

    utils=matcha/"matcha/utils/__init__.py"; pylogger=matcha/"matcha/utils/pylogger.py"
    utils_patch=patch_exact(utils,MATCHA_UTILS_BLOB,UTILS_REPLACEMENT,matcha,"matcha-utils-init-training-imports")
    pylogger_patch=patch_exact(pylogger,MATCHA_PYLOGGER_BLOB,PYLOGGER_REPLACEMENT,matcha,"matcha-pylogger-lightning-import")
    if "hydra" in utils.read_text() or "lightning" in utils.read_text()+pylogger.read_text(): raise RuntimeError("training-only Matcha dependency remains in sanitized utility import path")

    receipt={"schemaVersion":2,"status":"PASS_SOURCE_HYGIENE","sourceCommit":SOURCE_COMMIT,"matchaSubmoduleCommit":MATCHA_COMMIT,"target":ACOUSTICS.as_posix(),"originalGitBlob":ACOUSTICS_BLOB,"originalSha256":acoustics_before,"sanitizedSha256":acoustics_after,"matchaUtilsTarget":"matcha/utils/__init__.py","matchaUtilsOriginalGitBlob":MATCHA_UTILS_BLOB,"matchaUtilsSanitizedSha256":utils_patch["sanitizedSha256"],"matchaPyloggerTarget":"matcha/utils/pylogger.py","matchaPyloggerOriginalGitBlob":MATCHA_PYLOGGER_BLOB,"matchaPyloggerSanitizedSha256":pylogger_patch["sanitizedSha256"],"patches":[{"name":"developer-local-python-path","target":ACOUSTICS.as_posix(),"originalGitBlob":ACOUSTICS_BLOB,"originalSha256":acoustics_before,"sanitizedSha256":acoustics_after},utils_patch,pylogger_patch],"changes":["disable one developer-local Python 3.10 site-packages append","stop Matcha utils package from eagerly importing training/CLI utilities","replace Matcha distributed-training logger decoration with standard-library logging for conversion-only rebuild"],"runtimeMathChanged":False}
    output.parent.mkdir(parents=True,exist_ok=True); output.write_text(json.dumps(receipt,indent=2,sort_keys=True)+"\n"); print("[COSYVOICE3-REBUILD-HYGIENE] PASS "+json.dumps(receipt,sort_keys=True),flush=True)

if __name__=="__main__": main()

# Code purpose: keep the release rebuild hermetic and conversion-only without modifying model math or canonical development repositories.
# Upstream source: Ashtabula/CosyVoice3_NPU@878940245562bcd1dd0231d78157ba78d70b39f6 and Matcha-TTS@dd9105b34bf2be2230f4aa1e4769fb586a3c824e with exact Git blob guards.
# Runtime environment: Python 3 standard library inside the publication checkout.
# Generated: 2026-10-02 America/New_York.
# Changes: expands exact-blob-gated hygiene from the developer-local sys.path removal to Matcha utils eager training imports and Lightning-only logger decoration; all changes are temporary checkout hygiene and runtimeMathChanged remains false.
