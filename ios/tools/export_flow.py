# export_flow.py
# Requirement: preserve official DiT and validate estimator plus host Euler trajectory before optimization.
import json
import argparse
from pathlib import Path
import sys
import time
import numpy as np
import torch
import yaml
import coremltools as ct
from llm_graphs import ROOT,MODEL
from export_llm import metric
sys.path.insert(0,str(ROOT))
from cosyvoice.flow.DiT.dit import DiT

parser=argparse.ArgumentParser()
parser.add_argument("--stable-norm",action="store_true")
parser.add_argument("--ios18",action="store_true")
options=parser.parse_args()
suffix=("-stable-norm" if options.stable_norm else "")+("-ios18" if options.ios18 else "")
torch.set_num_threads(4)
fixture=ROOT/'ios/validation/phase0/run-002/tensors'
config=yaml.load((MODEL/'cosyvoice3.yaml').read_text(),Loader=yaml.BaseLoader)['flow']['decoder']['estimator']
kwargs={k:int(config[k]) for k in ['dim','depth','heads','dim_head','ff_mult','mel_dim','mu_dim','spk_dim','out_channels']}
estimator=DiT(**kwargs,static_chunk_size=50,num_decoding_left_chunks=-1).eval()
state=torch.load(MODEL/'flow.pt',map_location='cpu',weights_only=True,mmap=True)
prefix='decoder.estimator.'
estimator.load_state_dict({k[len(prefix):]:v for k,v in state.items() if k.startswith(prefix)},strict=True)
class Graph(torch.nn.Module):
    def __init__(self,m): super().__init__(); self.m=m
    def forward(self,x,mask,mu,t,spks,cond): return self.m(x,mask,mu,t,spks,cond,streaming=False)
class StableNorm(torch.nn.Module):
    def __init__(self, original):
        super().__init__(); self.eps=original.eps
    def forward(self,x):
        centered=x-x.mean(-1,keepdim=True)
        return centered*torch.rsqrt((centered*centered).mean(-1,keepdim=True)+self.eps)
def replace_norms(parent):
    for name,child in list(parent.named_children()):
        if isinstance(child,torch.nn.LayerNorm):
            assert not child.elementwise_affine
            setattr(parent,name,StableNorm(child))
        else: replace_norms(child)
if options.stable_norm: replace_norms(estimator)
model=Graph(estimator).eval()
records=[torch.load(fixture/f'estimator_{i:02d}.pt',weights_only=True) for i in range(10)]
xs=records[0]['args']
with torch.no_grad(): y=model(*xs)
receipt={'torch_vs_upstream':metric(y.numpy(),records[0]['output'].numpy()),'criteria':{'max_abs':0.005,'relative_l2':0.001},'config':kwargs,'shape':list(xs[0].shape),'coreml':'NOT_RUN'}
path=ROOT/f'ios/validation/flow/estimator-fp32{suffix}.json'
def save(): path.write_text(json.dumps(receipt,indent=2)+'\n'); print(json.dumps(receipt,indent=2),flush=True)
def ok(m): return m['max_abs']<=0.005 and m['relative_l2']<=0.001
save()
if not ok(receipt['torch_vs_upstream']): raise RuntimeError('Original DiT reload mismatch')
with torch.no_grad(): traced=torch.jit.trace(model,xs,check_trace=False)
names=['x','mask','mu','t','spks','cond']
start=time.perf_counter()
pipeline=ct.PassPipeline.DEFAULT
if options.stable_norm: pipeline.remove_passes({'common::fuse_layernorm_or_instancenorm'})
converted=ct.convert(traced,pass_pipeline=pipeline,inputs=[ct.TensorType(name=k,shape=v.shape,dtype=np.float32) for k,v in zip(names,xs)],outputs=[ct.TensorType(name='velocity')],
                     convert_to='mlprogram',minimum_deployment_target=ct.target.iOS18 if options.ios18 else ct.target.iOS17,compute_precision=ct.precision.FLOAT32,compute_units=ct.ComputeUnit.CPU_ONLY)
dest=ROOT/f'ios/converted/flow-estimator-fp32{suffix}.mlpackage'; converted.save(str(dest))
receipt['conversion_load_seconds']=time.perf_counter()-start
single=[]
for i,record in enumerate(records):
    prediction=converted.predict({k:v.numpy() for k,v in zip(names,record['args'])})['velocity']
    m=metric(prediction,record['output'].numpy()); single.append(m); print('ESTIMATOR',i,m,flush=True)
receipt['fixed_calls']=single
# Torch host scheduler precisely mirrors upstream time-grid and float32 update ordering.
span=1-torch.cos(torch.linspace(0,1,11)*0.5*torch.pi)
x=xs[0][0:1].clone(); t=span[0]; dt=span[1]-span[0]; trajectory=[]
for i in range(10):
    feed={k:v.numpy().copy() for k,v in zip(names,xs)}
    feed['x'][:]=x.numpy(); feed['t'][:]=t.item()
    velocity=torch.from_numpy(converted.predict(feed)['velocity'])
    guided=1.7*velocity[0:1]-0.7*velocity[1:2]
    x=x+dt*guided; t=t+dt
    if i<9:
        expected=records[i+1]['args'][0][0:1]
        trajectory.append(metric(x.numpy(),expected.numpy()))
        dt=span[i+2]-t
mel=x[:,:,302:]
expected_mel=torch.load(fixture/'flow_output.pt',weights_only=True)[0]
receipt['trajectory_steps']=trajectory; receipt['final_mel']=metric(mel.numpy(),expected_mel.numpy())
receipt['status']='PASS' if all(ok(m) for m in single+trajectory+[receipt['final_mel']]) else 'FAIL'
receipt['package_bytes']=sum(p.stat().st_size for p in dest.rglob('*') if p.is_file())
receipt['scope']='fixed 752-frame macOS CPU estimator and host scheduler; conditioning frontend and device not converted'
np.save(ROOT/f'ios/validation/flow/coreml-mel{suffix}.npy',mel.numpy()); save()
if receipt['status']!='PASS': raise RuntimeError('Flow parity failed')
# Purpose: original estimator conversion, scheduler kept on host; upstream: DiT + CausalConditionalCFM.
# Environment: .venv-coreml, local CPU; generated 2026-09-29 America/New_York; new file.

# Change 2026-09-29: lines 4, 20-23, 37-49 and export/output sites add separately named stable-norm diagnostic.

# Change 2026-09-29: CLI/export target lines add separately named iOS18 native-SDPA diagnostic.
