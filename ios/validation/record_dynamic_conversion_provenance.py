#!/usr/bin/env python3
#@title record_dynamic_conversion_provenance.py
# Requirement: extract exact Core ML conversion provenance from the physically accepted N1...479 family packages themselves, cross-check package metadata against the current dynamic conversion Python environment, and bind it to the exact family receipt SHA. Do not claim Xcode compilation as model conversion when it did not affect shipped mlpackage bytes.
from __future__ import annotations
import argparse,hashlib,json,platform,subprocess,sys,time
from pathlib import Path
import numpy as np
import torch
import coremltools as ct

ROOT=Path(__file__).resolve().parents[1]
REPO=ROOT.parent

def sha(path:Path)->str:
    h=hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda:f.read(8*1024*1024),b""): h.update(block)
    return h.hexdigest()

def tree_sha(path:Path)->str:
    h=hashlib.sha256()
    for p in sorted(x for x in path.rglob("*") if x.is_file()):
        rel=p.relative_to(path).as_posix()
        h.update(rel.encode());h.update(b"\0");h.update(str(p.stat().st_size).encode());h.update(b"\0");h.update(sha(p).encode());h.update(b"\n")
    return h.hexdigest()

def load(path:Path)->dict:
    value=json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value,dict): raise RuntimeError(f"JSON object required: {path}")
    return value

def find_family()->Path:
    root=ROOT/".work/dynamic-acoustic"
    rows=[]
    for p in root.glob("lower-bound-family-n1-v*"):
        try:
            r=load(p/"receipt.json")
            if r.get("status")=="PASS_FULL_RANGE_SYMBOLIC_FAMILY_EXPORT_NOT_PROMOTED" and r.get("NBounds")==[1,479]:
                rows.append((p.stat().st_mtime,p))
        except Exception:
            pass
    if not rows: raise RuntimeError("accepted N1 family not found under ios/.work/dynamic-acoustic")
    return max(rows)[1]

def package_metadata(path:Path)->dict:
    model=ct.models.MLModel(str(path),skip_model_load=True)
    metadata=dict(model.user_defined_metadata or {})
    return {str(k):str(v) for k,v in sorted(metadata.items())}

def main()->int:
    p=argparse.ArgumentParser()
    p.add_argument("--family",type=Path)
    p.add_argument("--output",type=Path,default=ROOT/"validation/evidence/dynamic_conversion_provenance.json")
    a=p.parse_args()
    family=(a.family.expanduser().resolve() if a.family else find_family().resolve())
    receipt_path=family/"receipt.json"
    if not receipt_path.is_file(): raise RuntimeError(f"family receipt missing: {receipt_path}")
    family_receipt=load(receipt_path)
    if family_receipt.get("status")!="PASS_FULL_RANGE_SYMBOLIC_FAMILY_EXPORT_NOT_PROMOTED" or family_receipt.get("NBounds")!=[1,479]:
        raise RuntimeError("family receipt is not accepted N1...479")

    packages=[
        ("conditions",family/"conditions/conditions.mlpackage"),
        *[(f"flow-{i}",family/f"packages/shard-{i:02d}/flow-shard.mlpackage") for i in range(6)],
        ("hift",family/"hift/hift-dynamic-body-fp32.mlpackage"),
    ]
    rows=[]
    metadata_versions=set()
    metadata_sources=set()
    for role,path in packages:
        if not path.is_dir(): raise RuntimeError(f"missing Core ML package: {path}")
        md=package_metadata(path)
        version=md.get("com.github.apple.coremltools.version")
        source=md.get("com.github.apple.coremltools.source")
        if not version: raise RuntimeError(f"{role} package lacks coremltools version metadata")
        if not source: raise RuntimeError(f"{role} package lacks coremltools source metadata")
        metadata_versions.add(version);metadata_sources.add(source)
        rows.append({
            "role":role,
            "packageTreeSha256":tree_sha(path),
            "coremltoolsVersionMetadata":version,
            "sourceMetadata":source,
            "sourceDialectMetadata":md.get("com.github.apple.coremltools.source_dialect"),
            "metadata":md,
        })
    if metadata_versions!={ct.__version__}:
        raise RuntimeError(f"package coremltools metadata {sorted(metadata_versions)} != conversion environment {ct.__version__}")
    torch_version=str(torch.__version__).split("+",1)[0]
    if not all(("torch" in source.lower() and torch_version in source) for source in metadata_sources):
        raise RuntimeError(f"package source metadata {sorted(metadata_sources)} does not match torch {torch_version}")

    exporter=ROOT/"experiments/dynamic-acoustic/export_full_range_family.py"
    head=subprocess.check_output(["git","-C",str(REPO),"rev-parse","HEAD"],text=True).strip()
    xcode=subprocess.check_output(["xcodebuild","-version"],text=True).strip()
    macos=subprocess.check_output(["sw_vers"],text=True).strip()
    out={
        "schemaVersion":1,
        "status":"PASS_DYNAMIC_CONVERSION_PROVENANCE_RECORDED",
        "releaseEngineeringSourceCommit":head,
        "familyReceiptSha256":sha(receipt_path),
        "familySourceCommit":family_receipt.get("sourceCommit"),
        "pinnedUpstream":family_receipt.get("pinnedUpstream"),
        "NBounds":[1,479],
        "conversionEnvironment":{
            "python":sys.version.splitlines()[0],
            "pythonExecutableRole":"project-local dynamic conversion environment",
            "platform":platform.platform(),
            "torch":str(torch.__version__),
            "coremltools":str(ct.__version__),
            "numpy":str(np.__version__),
            "xcodeObservedForCoreMLValidation":xcode,
            "macOS":macos,
            "note":"Core ML package metadata cryptographically belongs to the accepted family bytes; coremltools/source metadata is cross-checked against this conversion environment. Xcode coremlcompiler was used for validation compilation, not to generate the shipped mlpackage bytes."
        },
        "packages":rows,
        "productionPromotion":False,
        "recordedAtUnix":int(time.time())
    }
    a.output.parent.mkdir(parents=True,exist_ok=True)
    a.output.write_text(json.dumps(out,indent=2,sort_keys=True)+"\n",encoding="utf-8")
    print("[COSYVOICE3-DYNAMIC-CONVERSION] PASS "+json.dumps({
        "familyReceiptSha256":out["familyReceiptSha256"],
        "torch":out["conversionEnvironment"]["torch"],
        "coremltools":out["conversionEnvironment"]["coremltools"],
        "packageCount":len(rows)
    },sort_keys=True),flush=True)
    return 0

if __name__=="__main__": raise SystemExit(main())

# Code purpose: exact metadata-derived conversion provenance for the physically accepted dynamic N1...479 Core ML family.
# Upstream source: accepted N1 family receipt plus Core ML package user-defined conversion metadata.
# Runtime environment: the project-local dynamic Python environment with torch/coremltools, on the Mac release workstation.
# Generated time: 2026-10-04 America/New_York.
# Changes: new exact conversion-provenance gate; does not rebuild or alter validated package bytes.
