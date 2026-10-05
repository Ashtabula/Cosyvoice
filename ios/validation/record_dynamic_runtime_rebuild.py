#!/usr/bin/env python3
#@title record_dynamic_runtime_rebuild.py
# Requirement: prove a locally reconstructed dynamic N1...479 integration runtime and the immutable fetched RC converge on the same validated runtime ABI/manifest contract. Do not claim Core ML compiler byte identity unless bytes actually match.
from __future__ import annotations
import argparse,hashlib,json,subprocess,time
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
REPO=ROOT.parent

def load(path:Path)->dict:
    if not path.is_file(): raise RuntimeError(f"missing JSON: {path}")
    value=json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value,dict): raise RuntimeError(f"JSON object required: {path}")
    return value

def sha(path:Path)->str:
    h=hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda:f.read(8*1024*1024),b""):h.update(block)
    return h.hexdigest()

def normalized_dynamic(manifest:dict)->dict:
    d=manifest.get("dynamicAcoustic") or {}
    ref=manifest.get("referenceEnrollment") or {}
    return {
        "schemaVersion":manifest.get("schemaVersion"),
        "profile":manifest.get("profile"),
        "tokenizerFolder":manifest.get("tokenizerFolder"),
        "textEmbedding":manifest.get("textEmbedding"),
        "speechEmbedding":manifest.get("speechEmbedding"),
        "llmPrefill":manifest.get("llmPrefill"),
        "llmDecode":manifest.get("llmDecode"),
        "flowConditions":manifest.get("flowConditions"),
        "flowShards":manifest.get("flowShards"),
        "hift":manifest.get("hift"),
        "f0Folder":manifest.get("f0Folder"),
        "ropeTheta":manifest.get("ropeTheta"),
        "textEmbeddingRows":manifest.get("textEmbeddingRows"),
        "dynamicAcoustic":{
            "status":d.get("status"),
            "speechTokenMinimum":d.get("speechTokenMinimum"),
            "speechTokenMaximum":d.get("speechTokenMaximum"),
            "promptFrameCount":d.get("promptFrameCount"),
            "defaultPromptTokens":d.get("defaultPromptTokens"),
            "defaultPromptFeat":d.get("defaultPromptFeat"),
            "defaultSpeaker":d.get("defaultSpeaker"),
            "flowNoiseMaximum":d.get("flowNoiseMaximum"),
            "hiftExcitationMaximum":d.get("hiftExcitationMaximum"),
        },
        "referenceEnrollment":{
            "status":ref.get("status"),
            "speechTokenizer":ref.get("speechTokenizer"),
            "campPlus":ref.get("campPlus"),
            "whisperMel128":ref.get("whisperMel128"),
            "kaldiMel80":ref.get("kaldiMel80"),
            "matchaMel80":ref.get("matchaMel80"),
            "flowConditionsDynamic":ref.get("flowConditionsDynamic"),
            "promptTokenCount":ref.get("promptTokenCount"),
            "promptFrameCount":ref.get("promptFrameCount"),
        }
    }

def tree_rows(root:Path)->list[dict]:
    rows=[]
    for p in sorted(x for x in root.rglob("*") if x.is_file() and x.name!="asset-manifest.json"):
        rows.append({"path":p.relative_to(root).as_posix(),"bytes":p.stat().st_size,"sha256":sha(p)})
    return rows

def tree_id(rows:list[dict])->str:
    h=hashlib.sha256()
    for row in sorted(rows,key=lambda x:x["path"]):
        h.update(row["path"].encode());h.update(b"\0");h.update(str(row["bytes"]).encode());h.update(b"\0");h.update(row["sha256"].encode());h.update(b"\n")
    return h.hexdigest()

def main()->int:
    ap=argparse.ArgumentParser()
    ap.add_argument("--rebuilt-runtime",type=Path,required=True)
    ap.add_argument("--immutable-runtime",type=Path,required=True)
    ap.add_argument("--private-rc-receipt",type=Path,default=ROOT/"validation/evidence/dynamic_private_rc.json")
    ap.add_argument("--output",type=Path,default=ROOT/"validation/evidence/dynamic_runtime_rebuild.json")
    a=ap.parse_args()
    rebuilt=a.rebuilt_runtime.expanduser().resolve(); immutable=a.immutable_runtime.expanduser().resolve()
    for root in (rebuilt,immutable):
        subprocess.run(["python3",str(ROOT/"assets/validate_assets.py"),"--root",str(root),"--require-reference"],check=True)
    rman=load(rebuilt/"cosyvoice3_dynamic.json"); iman=load(immutable/"cosyvoice3_dynamic.json")
    if normalized_dynamic(rman)!=normalized_dynamic(iman):
        raise RuntimeError("rebuilt and immutable dynamic runtime ABI/manifest contracts differ")
    rcandidate=load(rebuilt/"dynamic-candidate-receipt.json")
    if rcandidate.get("status")!="PASS_DYNAMIC_CANDIDATE_ASSET_ROOT_BUILT_NOT_PROMOTED" or rcandidate.get("NBounds")!=[1,479]:
        raise RuntimeError("rebuilt runtime candidate receipt is not accepted N1...479")
    asset=load(immutable/"asset-manifest.json")
    private=load(a.private_rc_receipt.expanduser().resolve())
    if asset.get("profile")!="ios-dynamic-n1-n479-reference" or asset.get("speechTokenBounds")!=[1,479]:
        raise RuntimeError("immutable dynamic asset manifest identity/bounds mismatch")
    if private.get("status")!="PASS_DYNAMIC_PRIVATE_RC_IMMUTABLE_REPLAY":
        raise RuntimeError("private RC receipt is not PASS")
    if private.get("profile")!=asset.get("profile") or private.get("version")!=asset.get("assetVersion"):
        raise RuntimeError("private RC profile/version differs from immutable asset manifest")
    if private.get("payloadTreeSha256")!=asset.get("payloadTreeSha256"):
        raise RuntimeError("private RC payload tree differs from immutable asset manifest")
    if private.get("testedRuntimeTreeSha256")!=asset.get("testedRuntimeTreeSha256"):
        raise RuntimeError("private RC tested runtime tree differs from immutable asset manifest")
    immutable_rows=tree_rows(immutable)
    immutable_tree=tree_id(immutable_rows)
    if immutable_tree!=asset.get("payloadTreeSha256"):
        raise RuntimeError("immutable runtime payload tree differs from asset manifest")
    # Compare every runtime file shared by both roots. Release-evidence and asset-manifest
    # exist only in the hosted RC and are intentionally excluded from local runtime comparison.
    shared=[]
    exact=0
    for row in tree_rows(rebuilt):
        p=immutable/row["path"]
        if not p.is_file(): continue
        same=p.stat().st_size==row["bytes"] and sha(p)==row["sha256"]
        shared.append({"path":row["path"],"exact":same})
        exact+=int(same)
    if not shared: raise RuntimeError("no shared runtime files to compare")
    nonexact=[x["path"] for x in shared if not x["exact"]]
    head=subprocess.check_output(["git","-C",str(REPO),"rev-parse","HEAD"],text=True).strip()
    receipt={
        "schemaVersion":1,
        "status":"PASS_SUPPORTED_DYNAMIC_RUNTIME_REBUILD_CONTRACT",
        "sourceCommit":head,
        "profile":"ios-dynamic-n1-n479-reference",
        "runtimeProfile":"ios18-dynamic-n1-n479",
        "NBounds":[1,479],
        "manifestContractExact":True,
        "sharedRuntimeFileCount":len(shared),
        "byteExactSharedRuntimeFileCount":exact,
        "nonByteExactSharedRuntimeFiles":nonexact,
        "byteIdentityClaim":len(nonexact)==0,
        "byteIdentityMeaning":"true only when every shared runtime file is byte-identical; Candidate acceptance requires ABI/validator convergence, not compiler serialization identity",
        "immutablePayloadTreeSha256":immutable_tree,
        "immutableRevision":private.get("revision"),
        "immutableRepoId":private.get("repoId"),
        "immutableVersion":private.get("version"),
        "validatedRuntimeSourceCommit":private.get("validatedRuntimeSourceCommit"),
        "rebuildSemantics":{
            "productionDefaultFlowSteps":6,
            "validatedPublicFlowSteps":[6,8,10],
            "speechTokenBounds":[1,479],
            "generationContract":"min(targetTextTokens*20,512-logicalPrefixLength)",
            "modelConversionRole":"maintainer/release-engineering; ordinary consumers fetch immutable validated assets"
        },
        "recordedAtUnix":int(time.time())
    }
    a.output.parent.mkdir(parents=True,exist_ok=True)
    a.output.write_text(json.dumps(receipt,indent=2,sort_keys=True)+"\n",encoding="utf-8")
    print("[COSYVOICE3-DYNAMIC-REBUILD] PASS "+json.dumps(receipt,sort_keys=True),flush=True)
    return 0

if __name__=="__main__": raise SystemExit(main())

# Code purpose: dynamic immutable-vs-local runtime ABI convergence receipt without false Core ML byte-reproducibility claims.
# Upstream source: build_n1_dynamic_candidate.sh output and ordinary-fetched immutable dynamic private RC.
# Runtime environment: canonical macOS release host, Python3.
# Generated time: 2026-10-04 America/New_York.
# Changes: new supported dynamic runtime rebuild/convergence gate.

# Changes 2026-10-04: rebuild convergence now binds the immutable runtime to the committed dynamic_private_rc.json revision/repo/version/tree instead of reading a non-existent revision field from asset-manifest.json.
