#!/usr/bin/env python3
# record_dynamic_listening_acceptance.py
# Requirement: record explicit human listening acceptance for the exact default/reference WAVs emitted by one PASS dynamic public-API smoke. Verify receipt status, WAV SHA256, PCM-derived N and source commit before recording acceptance; never infer human quality from numerical/shape PASS.
from __future__ import annotations
import argparse,hashlib,json,time,wave
from pathlib import Path

def sha(path:Path)->str:
    h=hashlib.sha256()
    with path.open("rb") as f:
        for b in iter(lambda:f.read(8*1024*1024),b""):h.update(b)
    return h.hexdigest()

def require(v,msg):
    if not v:raise RuntimeError(msg)

def wav_info(path:Path):
    with wave.open(str(path),"rb") as w:
        return {"channels":w.getnchannels(),"sampleRate":w.getframerate(),"frames":w.getnframes(),"sampleWidth":w.getsampwidth()}

def main():
    p=argparse.ArgumentParser()
    p.add_argument("--smoke-receipt",type=Path,required=True)
    p.add_argument("--default-wav",type=Path,required=True)
    p.add_argument("--reference-wav",type=Path,required=True)
    p.add_argument("--default",choices=("ACCEPT","REJECT"),required=True)
    p.add_argument("--reference",choices=("ACCEPT","REJECT"),required=True)
    p.add_argument("--notes",default="")
    p.add_argument("--output",type=Path,required=True)
    a=p.parse_args()
    require(not a.output.exists(),"output already exists")
    r=json.loads(a.smoke_receipt.read_text())
    require(r.get("status")=="PASS_DYNAMIC_PUBLIC_API_DEFAULT_AND_REFERENCE","smoke receipt is not PASS")
    require(str(r.get("profile","")).startswith("ios18-dynamic-"),"smoke profile is not dynamic")
    require(r.get("productionPromotion") is False,"input smoke unexpectedly claims production promotion")
    lo,hi=map(int,r["speechTokenBounds"])
    lanes={"default":(a.default_wav,a.default),"reference":(a.reference_wav,a.reference)}
    output_lanes={}
    for lane,(wav_path,decision) in lanes.items():
        require(wav_path.is_file(),f"missing {lane} WAV: {wav_path}")
        expected=r[lane]
        actual_sha=sha(wav_path)
        require(actual_sha==expected["wavSha256"],f"{lane} WAV SHA mismatch")
        n=int(expected["inferredSpeechTokensFromPCM"]);samples=int(expected["samples"])
        require(lo<=n<=hi,f"{lane} N outside receipt bounds")
        require(samples==960*n,f"{lane} PCM != 960*N")
        info=wav_info(wav_path)
        require(info["channels"]==1 and info["sampleRate"]==24000,f"{lane} WAV format mismatch: {info}")
        require(info["frames"]==samples,f"{lane} WAV frame count mismatch: {info['frames']} != {samples}")
        output_lanes[lane]={
            "decision":decision,"wavSha256":actual_sha,"N":n,"samples":samples,
            "durationSeconds":samples/24000.0,"wav":info
        }
    accepted=a.default=="ACCEPT" and a.reference=="ACCEPT"
    out={
        "schemaVersion":1,
        "status":"PASS_DYNAMIC_LISTENING_ACCEPTANCE" if accepted else "REJECT_DYNAMIC_LISTENING_ACCEPTANCE",
        "recordedAtUnix":int(time.time()),
        "sourceCommit":r.get("sourceCommit"),
        "profile":r.get("profile"),
        "speechTokenBounds":[lo,hi],
        "smokeReceiptSha256":sha(a.smoke_receipt),
        "lanes":output_lanes,
        "notes":a.notes,
        "humanDecisionRequired":True,
        "productionPromotion":False
    }
    a.output.parent.mkdir(parents=True,exist_ok=True)
    a.output.write_text(json.dumps(out,indent=2,sort_keys=True)+"\n")
    print(json.dumps(out,indent=2,sort_keys=True))
    return 0 if accepted else 1

if __name__=="__main__":raise SystemExit(main())

# Code purpose: bind human audible-quality acceptance/rejection to exact dynamic public-API smoke WAV bytes and receipt metadata.
# Upstream source: physical DeviceSmoke dynamic-public-api-smoke-receipt.json plus its emitted default/reference WAV files.
# Runtime environment: Python3 standard library on validation host.
# Generated time: 2026-10-04 America/New_York.
# Changes: new human-gated quality receipt; numerical PASS never substitutes for listening acceptance.
