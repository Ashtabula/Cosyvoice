#@title sanitize_rebuild_source.py
# Requirement: remove the one developer-local Python site-packages escape hatch from the pinned temporary upstream checkout only after verifying the exact locked Git blob, and emit a machine-readable hygiene receipt.
from __future__ import annotations
import argparse,hashlib,json,subprocess
from pathlib import Path

SOURCE_COMMIT="878940245562bcd1dd0231d78157ba78d70b39f6"
TARGET=Path("iOS/tools/export_pipeline_acoustics.py")
EXPECTED_GIT_BLOB="2e0eb4dc5d9216db07207e5564f13a38c4ad2e74"
FORBIDDEN="sys.path.append('/Volumes/WD/Codes/CosyVoice3/.venv-upstream/lib/python3.10/site-packages')"

def sha256(path:Path)->str:
    h=hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda:f.read(1024*1024),b""): h.update(block)
    return h.hexdigest()

def main():
    p=argparse.ArgumentParser(); p.add_argument("--source-root",type=Path,required=True); p.add_argument("--output",type=Path,required=True); a=p.parse_args()
    source=a.source_root.resolve(); target=source/TARGET; output=a.output.resolve()
    head=subprocess.check_output(["git","-C",str(source),"rev-parse","HEAD"],text=True).strip()
    if head!=SOURCE_COMMIT: raise RuntimeError(f"source HEAD mismatch: {head}")
    blob=subprocess.check_output(["git","-C",str(source),"rev-parse",f"HEAD:{TARGET.as_posix()}"],text=True).strip()
    if blob!=EXPECTED_GIT_BLOB: raise RuntimeError(f"unexpected upstream acoustics blob: {blob}")
    text=target.read_text()
    if text.count(FORBIDDEN)!=1: raise RuntimeError("expected exactly one developer-local sys.path escape hatch")
    before=sha256(target); target.write_text(text.replace(FORBIDDEN,"# release rebuild: developer-local Python site-packages path intentionally disabled"))
    after=sha256(target)
    if "/Volumes/WD/Codes/CosyVoice3/.venv-upstream" in target.read_text(): raise RuntimeError("developer-local upstream venv path remains after sanitation")
    receipt={"schemaVersion":1,"status":"PASS_SOURCE_HYGIENE","sourceCommit":SOURCE_COMMIT,"target":TARGET.as_posix(),"originalGitBlob":EXPECTED_GIT_BLOB,"originalSha256":before,"sanitizedSha256":after,"change":"remove developer-local Python 3.10 site-packages sys.path append only","runtimeMathChanged":False}
    output.parent.mkdir(parents=True,exist_ok=True); output.write_text(json.dumps(receipt,indent=2,sort_keys=True)+"\n"); print("[COSYVOICE3-REBUILD-HYGIENE] PASS "+json.dumps(receipt,sort_keys=True),flush=True)

if __name__=="__main__": main()

# Code purpose: make the clean release rebuild hermetic without modifying model math or the canonical development repository.
# Upstream source: Ashtabula/CosyVoice3_NPU@878940245562bcd1dd0231d78157ba78d70b39f6, verified export_pipeline_acoustics.py Git blob 2e0eb4dc5d9216db07207e5564f13a38c4ad2e74.
# Runtime environment: Python 3 standard library inside the publication checkout.
# Generated: 2026-10-02 America/New_York.
# Changes: new file; exact-blob-gated removal of one developer-local sys.path.append and machine-readable hygiene receipt.
