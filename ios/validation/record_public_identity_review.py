#!/usr/bin/env python3
#@title record_public_identity_review.py
# Requirement: verify a fresh one-commit public snapshot has canonical actacomes author/committer identity and byte/mode-identical public tree, then record the exact public snapshot commit without publishing it.
from __future__ import annotations
import argparse,hashlib,json,subprocess,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]; REPO=ROOT.parent
def run(*a,cwd=None): return subprocess.check_output(list(a),cwd=cwd,text=True).strip()
def snapshot_rows(repo):
    files=run("git","ls-files",cwd=repo).splitlines(); rows=[]
    for p in files:
        data=subprocess.check_output(["git","show",f"HEAD:{p}"],cwd=repo); mode=run("git","ls-files","-s","--",p,cwd=repo).split()[0]
        rows.append({"path":p,"mode":mode,"bytes":len(data),"sha256":hashlib.sha256(data).hexdigest()})
    return sorted(rows,key=lambda x:x["path"])
def tree_id(rows):
    h=hashlib.sha256()
    for r in rows: h.update(f'{r["path"]}\0{r["mode"]}\0{r["bytes"]}\0{r["sha256"]}\n'.encode())
    return h.hexdigest()
def main():
    p=argparse.ArgumentParser(); p.add_argument("--snapshot",type=Path,required=True); p.add_argument("--output",type=Path,default=ROOT/"validation/evidence/public_identity_review.json"); a=p.parse_args(); s=a.snapshot.resolve()
    subprocess.run(["python3",str(REPO/"tools/check_public_identity.py")],check=True)
    subprocess.run(["python3",str(REPO/"tools/check_public_identity.py"),"--root",str(s),"--content-only"],check=True)
    if run("git","rev-list","--count","HEAD",cwd=s)!="1": raise RuntimeError("public snapshot must have exactly one commit")
    if subprocess.run(["git","diff","--quiet"],cwd=s).returncode!=0 or subprocess.run(["git","diff","--cached","--quiet"],cwd=s).returncode!=0: raise RuntimeError("public snapshot worktree is not clean")
    expected="actacomes <developer@actacomes.com>"; author=run("git","log","-1","--format=%an <%ae>",cwd=s); committer=run("git","log","-1","--format=%cn <%ce>",cwd=s)
    if author!=expected or committer!=expected: raise RuntimeError("public snapshot author/committer identity mismatch")
    release_tree=json.loads((ROOT/"validation/evidence/release_tree_reproducible.json").read_text()); tree=tree_id(snapshot_rows(s))
    if tree!=release_tree["publicationTreeSha256"]: raise RuntimeError(f"public snapshot tree {tree} != frozen release tree {release_tree['publicationTreeSha256']}")
    receipt={"schemaVersion":1,"status":"PASS_PUBLIC_IDENTITY_REVIEW","privateSourceCommit":run("git","-C",str(REPO),"rev-parse","HEAD"),"publicSnapshotCommit":run("git","rev-parse","HEAD",cwd=s),"publicationTreeSha256":tree,"author":author,"committer":committer,"publicRepositoryTarget":"actacomes/Cosyvoice","sourceIdentityScan":"PASS","finalSnapshotIdentityScan":"PASS","publicRedistributionApproved":False,"recordedAtUnix":int(time.time())}
    a.output.parent.mkdir(parents=True,exist_ok=True); a.output.write_text(json.dumps(receipt,indent=2,sort_keys=True)+"\n"); print("[COSYVOICE3-PUBLIC-IDENTITY-REVIEW] PASS "+json.dumps(receipt,sort_keys=True),flush=True)
if __name__=="__main__": main()
# Code purpose: exact fresh-public-history identity/tree review; does not create a remote, push, approve licensing or publish assets.
# Runtime environment: Python 3 standard library + Git.
# Generated time: 2026-10-03 America/New_York.

# Changes 2026-10-04: public identity review now scans both the private release source and the exact fresh public snapshot content with the complete identity family before accepting author/committer/tree identity.
