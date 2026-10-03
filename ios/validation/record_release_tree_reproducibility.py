#!/usr/bin/env python3
#@title record_release_tree_reproducibility.py
# Requirement: prove that the explicit public SDK snapshot scope is deterministically reproducible from the exact Git commit and emit a machine-readable receipt.
from __future__ import annotations
import argparse,hashlib,io,json,subprocess,tarfile,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]; REPO=ROOT.parent; PATHS=ROOT/"public_snapshot_paths.txt"
def specs(): return [x.strip() for x in PATHS.read_text().splitlines() if x.strip() and not x.lstrip().startswith("#")]
def selected():
    tracked=subprocess.check_output(["git","-C",str(REPO),"ls-files"],text=True).splitlines(); out=["LICENSE"]
    for spec in specs():
        p="ios/"+spec
        if spec.endswith("/"): rows=[x for x in tracked if x.startswith(p)]
        else: rows=[p] if p in tracked else []
        if not rows: raise RuntimeError(f"public snapshot spec has no tracked files: {spec}")
        out+=rows
    return sorted(set(out))
def blob(path): return subprocess.check_output(["git","-C",str(REPO),"show",f"HEAD:{path}"])
def dest(path): return path[4:] if path.startswith("ios/") else path
def rows(paths):
    out=[]
    for p in paths:
        data=blob(p); mode=subprocess.check_output(["git","-C",str(REPO),"ls-files","-s","--",p],text=True).split()[0]
        out.append({"path":dest(p),"sourcePath":p,"mode":mode,"bytes":len(data),"sha256":hashlib.sha256(data).hexdigest()})
    return sorted(out,key=lambda x:x["path"])
def tree_id(rs):
    h=hashlib.sha256()
    for r in rs: h.update(f'{r["path"]}\0{r["mode"]}\0{r["bytes"]}\0{r["sha256"]}\n'.encode())
    return h.hexdigest()
def archive(paths):
    return subprocess.check_output(["git","-C",str(REPO),"archive","--format=tar","HEAD","--",*paths])
def main():
    p=argparse.ArgumentParser(); p.add_argument("--output",type=Path,default=ROOT/"validation/evidence/release_tree_reproducible.json"); p.add_argument("--check-only",action="store_true"); p.add_argument("--expect-tree-sha256"); a=p.parse_args()
    paths=selected()
    if subprocess.run(["git","-C",str(REPO),"diff","--quiet","HEAD","--",*paths]).returncode!=0: raise RuntimeError("public snapshot scope has uncommitted tracked changes")
    rs=rows(paths); a1=archive(paths); a2=archive(paths)
    if hashlib.sha256(a1).digest()!=hashlib.sha256(a2).digest(): raise RuntimeError("git archive is not deterministic across repeated export")
    with tarfile.open(fileobj=io.BytesIO(a1),mode="r:") as tf:
        amap={m.name:hashlib.sha256(tf.extractfile(m).read()).hexdigest() for m in tf.getmembers() if m.isfile()}
    for r in rs:
        if amap.get(r["sourcePath"])!=r["sha256"]: raise RuntimeError(f"archive/content mismatch: {r['sourcePath']}")
    head=subprocess.check_output(["git","-C",str(REPO),"rev-parse","HEAD"],text=True).strip(); baseline=json.loads((ROOT/"validation/production_baseline.json").read_text())
    tree=tree_id(rs)
    if a.expect_tree_sha256 and tree!=a.expect_tree_sha256: raise RuntimeError(f"public snapshot tree changed: {tree} != {a.expect_tree_sha256}")
    receipt={"schemaVersion":1,"status":"PASS_RELEASE_TREE_REPRODUCIBLE","sourceCommit":head,"candidateReleaseHead":baseline["candidateReleaseHead"],"validatedSourceCommit":baseline["validatedSourceCommit"],"publicationTreeSha256":tree,"fileCount":len(rs),"archiveSha256":hashlib.sha256(a1).hexdigest(),"scope":"ios/public_snapshot_paths.txt + repository LICENSE","recordedAtUnix":int(time.time())}
    if not a.check_only: a.output.parent.mkdir(parents=True,exist_ok=True); a.output.write_text(json.dumps(receipt,indent=2,sort_keys=True)+"\n")
    print("[COSYVOICE3-RELEASE-TREE] PASS "+json.dumps(receipt,sort_keys=True),flush=True)
if __name__=="__main__": main()
# Code purpose: deterministic public-snapshot tree/archive proof bound to the exact private release commit.
# Runtime environment: Python 3 standard library + Git.
# Generated time: 2026-10-03 America/New_York.


# Changes 2026-10-03: optional --expect-tree-sha256 lets later Production gates prove the public snapshot scope has not drifted since the committed reproducibility receipt.
