# validate_llm_rollout.py
# Requirement: validate persistent Core ML KV updates over the entire frozen token trajectory.
import json
import sys
import time
import numpy as np
import torch
import coremltools as ct
from llm_graphs import ROOT,MODEL,SpeechLLM,inputs,rope
from export_llm import metric
sys.path.insert(0,str(ROOT))
from cosyvoice.utils.common import ras_sampling

torch.set_num_threads(4)
fixture=ROOT/'ios/validation/phase0/run-002/tensors'
model=SpeechLLM('prefill',512).eval()
xs=inputs(model,fixture,'prefill')
config=model.config
names=['x','cos','sin','mask','keys','values','write_mask']
prefill=ct.models.MLModel(str(ROOT/'ios/converted/llm-prefill-fp32.mlpackage'),compute_units=ct.ComputeUnit.CPU_ONLY)
decode=ct.models.MLModel(str(ROOT/'ios/converted/llm-decode-fp32.mlpackage'),compute_units=ct.ComputeUnit.CPU_ONLY)
state=torch.load(MODEL/'llm.pt',map_location='cpu',weights_only=True,mmap=True)
embedding=state['speech_embedding.weight']
reference=torch.load(fixture/'llm_logits.pt',weights_only=True).numpy()
tokens=torch.load(fixture/'generated_speech_tokens.pt',weights_only=True).tolist()
result=prefill.predict({k:v.numpy() for k,v in zip(names,xs)})
length=xs[0].shape[1]
rows=[]; outputs=[]
start=time.perf_counter()
for step in range(len(reference)):
    current=result['logits']; outputs.append(current)
    m=metric(current,reference[step:step+1]); m['step']=step
    m['argmax_match']=bool(np.argmax(current)==np.argmax(reference[step]))
    rows.append(m)
    if step%25==0: print('ROLLOUT',step,m,flush=True)
    if step==len(reference)-1: break
    pos=length+step
    if pos>=512: raise RuntimeError('KV capacity exceeded')
    cos,sin=rope(config,[pos])
    mask=np.full((1,1,1,512),np.finfo(np.float32).min,dtype=np.float32); mask[:,:,:,:pos+1]=0
    write=np.zeros((1,1,512,1),dtype=np.float32); write[:,:,pos,:]=1
    result=decode.predict({'x':embedding[tokens[step]].reshape(1,1,-1).numpy(),'cos':cos.numpy(),'sin':sin.numpy(),
                           'mask':mask,'keys':result['new_keys'],'values':result['new_values'],'write_mask':write})
all_logits=np.concatenate(outputs)
# Compare upstream RAS using identical starting RNG, both fixed logit trajectories.
def sample_trajectory(logits):
    torch.set_rng_state(torch.load(fixture/'rng_before_inference.pt',weights_only=True))
    chosen=[]
    for i,row in enumerate(logits):
        scores=torch.from_numpy(row.copy()).log_softmax(-1)
        if i<64: scores[6561]=-float('inf')
        token=ras_sampling(scores,chosen,25)
        chosen.append(token)
        if token>=6561: break
    return chosen
upstream_samples=sample_trajectory(reference)
converted_samples=sample_trajectory(all_logits)
passed=all(r['max_abs']<=0.005 and r['relative_l2']<=0.001 and r['argmax_match'] for r in rows)
receipt={'status':'PASS' if passed else 'FAIL','rows':rows,'steps':len(rows),'elapsed_seconds':time.perf_counter()-start,
         'maximum_logit_abs_error':max(r['max_abs'] for r in rows),'all_argmax_match':all(r['argmax_match'] for r in rows),
         'ras_fixed_trajectory_samples_match':upstream_samples==converted_samples,
         'upstream_ras_replay_matches_captured_tokens':upstream_samples[:-1]==tokens,
         'scope':'teacher-forced rolling Core ML cache, not autonomous sampled generation or device test',
         'capacity':512,'final_cache_valid_length':length+len(rows)-1,'compute_units':'CPU_ONLY'}
(ROOT/'ios/validation/llm/rollout-fp32.json').write_text(json.dumps(receipt,indent=2)+'\n')
np.save(ROOT/'ios/validation/llm/rollout-logits.npy',all_logits)
print(json.dumps({k:v for k,v in receipt.items() if k!='rows'},indent=2))
if not passed: raise RuntimeError('Rolling KV parity failed')
# Purpose: multi-step cache verification; upstream: frozen official logits/tokens and upstream RAS.
# Environment: .venv-coreml, local CPU; generated 2026-09-29 America/New_York; new file.
