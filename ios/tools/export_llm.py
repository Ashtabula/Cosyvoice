# export_llm.py
# Requirement: compare explicit-KV PyTorch graph with frozen upstream, then convert and test Core ML.
import argparse
import hashlib
import json
from pathlib import Path
import time
import numpy as np
import torch
import coremltools as ct
from llm_graphs import SpeechLLM,inputs,ROOT


def metric(actual,expected):
    a=np.asarray(actual,dtype=np.float64); b=np.asarray(expected,dtype=np.float64)
    return {'max_abs':float(np.max(np.abs(a-b))),'rmse':float(np.sqrt(np.mean((a-b)**2))),
            'relative_l2':float(np.linalg.norm(a-b)/max(np.linalg.norm(b),1e-12))}


def main():
    p=argparse.ArgumentParser(); p.add_argument('--mode',choices=['prefill','decode'],required=True)
    p.add_argument('--capacity',type=int,default=512); p.add_argument('--convert',action='store_true')
    args=p.parse_args(); torch.set_num_threads(4)
    fixture=ROOT/'ios/validation/phase0/run-002/tensors'
    model=SpeechLLM(args.mode,args.capacity).eval(); xs=inputs(model,fixture,args.mode)
    n=0 if args.mode=='prefill' else 1
    oracle=torch.load(fixture/f'llm_step_{n:03d}_output.pt',weights_only=True)
    logits=torch.load(fixture/'llm_logits.pt',weights_only=True)[n:n+1]
    length=oracle[1][0][0].shape[2]
    expected=[logits.numpy(),torch.stack([c[0] for c in oracle[1]]).numpy(),torch.stack([c[1] for c in oracle[1]]).numpy(),oracle[0][:,-1,:].numpy()]
    def compare(outputs):
        arrays=[v.detach().numpy() if isinstance(v,torch.Tensor) else v for v in outputs]
        arrays[1]=arrays[1][:,:,:,:length]; arrays[2]=arrays[2][:,:,:,:length]
        result={name:metric(a,b) for name,a,b in zip(['logits','keys','values','hidden'],arrays,expected)}
        result['argmax_match']=bool(np.argmax(arrays[0])==np.argmax(expected[0]))
        # Fixed FP32 acceptance criteria; failures are reported without loosening the gate.
        result['pass']=all(v['max_abs']<=0.005 and v['relative_l2']<=0.001 for v in result.values() if isinstance(v,dict)) and result['argmax_match']
        return result
    with torch.no_grad(): result=model(*xs)
    receipt={'mode':args.mode,'capacity':args.capacity,'dtype':'float32','torch_vs_upstream':compare(result),'coreml':'NOT_RUN',
             'criteria':{'max_abs':0.005,'relative_l2':0.001,'argmax_match':True},'coremltools':ct.__version__,'torch':torch.__version__}
    output=ROOT/f'ios/validation/llm/{args.mode}-fp32.json'
    def save(): output.write_text(json.dumps(receipt,indent=2)+'\n'); print(json.dumps(receipt,indent=2),flush=True)
    save()
    if not receipt['torch_vs_upstream']['pass']: raise RuntimeError('PyTorch decomposition parity failed')
    if not args.convert: return
    with torch.no_grad(): traced=torch.jit.trace(model,xs,check_trace=False)
    names=['x','cos','sin','mask','keys','values','write_mask']; outs=['logits','new_keys','new_values','hidden']
    start=time.perf_counter()
    converted=ct.convert(traced,inputs=[ct.TensorType(name=k,shape=v.shape,dtype=np.float32) for k,v in zip(names,xs)],
                         outputs=[ct.TensorType(name=k) for k in outs],minimum_deployment_target=ct.target.iOS17,
                         convert_to='mlprogram',compute_precision=ct.precision.FLOAT32,compute_units=ct.ComputeUnit.CPU_ONLY)
    dest=ROOT/f'ios/converted/llm-{args.mode}-fp32.mlpackage'; converted.save(str(dest))
    receipt['convert_load_seconds']=time.perf_counter()-start
    start=time.perf_counter(); prediction=converted.predict({k:v.numpy() for k,v in zip(names,xs)})
    receipt['predict_seconds']=time.perf_counter()-start
    receipt['coreml']=compare([prediction[k] for k in outs]); receipt['package_bytes']=sum(p.stat().st_size for p in dest.rglob('*') if p.is_file())
    receipt['compute_units']='CPU_ONLY'; receipt['scope']='macOS fixture parity; not iPhone or ANE proof'
    save()
    if not receipt['coreml']['pass']: raise RuntimeError('Core ML parity failed')

if __name__=='__main__': main()
# Purpose: first fixture-specific FP32 LLM conversion; upstream: frozen Phase 0 and llm_graphs.py.
# Environment: .venv-coreml, local macOS CPU; generated 2026-09-29 America/New_York; new file.
