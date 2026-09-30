# verify_baseline.py
# Requirement: verify captured fixtures and repeatability without equating WAV metadata with PCM.
import argparse
import hashlib
import json
from pathlib import Path
import struct
import numpy as np
import soundfile as sf
import torch


def digest(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda:f.read(8*1024*1024),b''): h.update(block)
    return h.hexdigest()


def compare(a,b,path=''):
    if isinstance(a,torch.Tensor):
        if not isinstance(b,torch.Tensor) or a.dtype!=b.dtype or a.shape!=b.shape or not torch.equal(a,b):
            raise AssertionError('Tensor differs: '+path)
    elif isinstance(a,dict):
        assert a.keys()==b.keys(),path
        for k in a: compare(a[k],b[k],path+'/'+str(k))
    elif isinstance(a,(tuple,list)):
        assert len(a)==len(b),path
        for i,(x,y) in enumerate(zip(a,b)): compare(x,y,path+'/'+str(i))
    else:
        assert a==b,path


def chunks(path):
    b=path.read_bytes(); result={}; pos=12
    assert b[:4]==b'RIFF' and b[8:12]==b'WAVE'
    while pos+8<=len(b):
        name=b[pos:pos+4].decode('ascii'); size=struct.unpack('<I',b[pos+4:pos+8])[0]
        result[name]=b[pos+8:pos+8+size]
        pos+=8+size+(size%2)
    return result


def main():
    p=argparse.ArgumentParser()
    p.add_argument('first',type=Path); p.add_argument('second',type=Path); p.add_argument('--output',type=Path,required=True)
    args=p.parse_args()
    receipts=[json.loads((d/'receipt.json').read_text()) for d in [args.first,args.second]]
    for d,r in zip([args.first,args.second],receipts):
        assert r['status']=='AUTOMATED_CAPTURE_PASS'
        assert digest(d/'baseline.wav')==r['wav_sha256']
        for name,capture in r['captures'].items():
            assert digest(d/capture['file'])==capture['sha256'],name
    assert receipts[0]['model_revision']==receipts[1]['model_revision']
    assert receipts[0]['source_revision']==receipts[1]['source_revision']
    assert receipts[0]['captures'].keys()==receipts[1]['captures'].keys()
    for name in receipts[0]['captures']:
        a=torch.load(args.first/receipts[0]['captures'][name]['file'],weights_only=True)
        b=torch.load(args.second/receipts[1]['captures'][name]['file'],weights_only=True)
        compare(a,b,name)
    a,sr=sf.read(args.first/'baseline.wav',dtype='float32')
    b,sr2=sf.read(args.second/'baseline.wav',dtype='float32')
    assert sr==sr2==24000 and a.ndim==b.ndim==1 and len(a)>0
    assert np.isfinite(a).all() and np.array_equal(a,b)
    ca=chunks(args.first/'baseline.wav'); cb=chunks(args.second/'baseline.wav')
    assert ca.keys()==cb.keys()
    different=[k for k in ca if ca[k]!=cb[k]]
    assert all(k=='PEAK' for k in different),different
    for k in different:
        # libsndfile's PEAK chunk stores a wall-clock timestamp at bytes 4..7.
        assert ca[k][:4]==cb[k][:4] and ca[k][8:]==cb[k][8:]
    result={'status':'PASS','scope':'local CPU repeated official zero-shot inference; all captured tensors bitwise equal',
            'runs':[str(args.first),str(args.second)],'fixture_hashes_verified':True,
            'capture_count':len(receipts[0]['captures']),'sample_rate':sr,'samples':len(a),
            'pcm_sha256':hashlib.sha256(a.tobytes()).hexdigest(),
            'wav_file_hashes':[r['wav_sha256'] for r in receipts],
            'wav_container_difference':'PEAK timestamp only' if different else None,
            'human_listening':'PENDING','ane_residency':'NOT_TESTED','iphone':'NOT_TESTED'}
    args.output.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2))

if __name__=='__main__': main()
# Purpose: verify real baseline reproducibility; upstream: capture_baseline.py and official inference.
# Environment: .venv-upstream; generated 2026-09-29 America/New_York; new file, all lines added.
