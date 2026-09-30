# probe_flow_components.py
# Requirement: localize FP32 DiT conversion drift without relaxing parity thresholds.
import json
import sys
import torch
import numpy as np
import coremltools as ct
from llm_graphs import ROOT,MODEL
from export_llm import metric
sys.path.insert(0,str(ROOT))
from cosyvoice.flow.DiT.dit import DiT

torch.set_num_threads(4)
m=DiT(dim=1024,depth=22,heads=16,dim_head=64,ff_mult=2,mel_dim=80,mu_dim=80,spk_dim=80,out_channels=80,static_chunk_size=50,num_decoding_left_chunks=-1).eval()
s=torch.load(MODEL/'flow.pt',weights_only=True,map_location='cpu',mmap=True)
m.load_state_dict({k[len('decoder.estimator.'):]:v for k,v in s.items() if k.startswith('decoder.estimator.')})
fixture=ROOT/'ios/validation/phase0/run-002/tensors'
r=torch.load(fixture/'estimator_08.pt',weights_only=True)['args']
class Input(torch.nn.Module):
    def __init__(self): super().__init__(); self.embed=m.input_embed
    def forward(self,x,cond,mu,spks): return self.embed(x.transpose(1,2),cond.transpose(1,2),mu.transpose(1,2),spks)
probes=[('time_sinus',m.time_embed.time_embed,(r[3],)),('time_full',m.time_embed,(r[3],)),('input',Input().eval(),(r[0],r[5],r[2],r[4]))]
results={}
for name,module,xs in probes:
    with torch.no_grad():
        expected=module(*xs); trace=torch.jit.trace(module,xs,check_trace=False)
    converted=ct.convert(trace,inputs=[ct.TensorType(name=f'x{i}',shape=x.shape) for i,x in enumerate(xs)],outputs=[ct.TensorType(name='y')],compute_precision=ct.precision.FLOAT32,compute_units=ct.ComputeUnit.CPU_ONLY,minimum_deployment_target=ct.target.iOS17)
    actual=converted.predict({f'x{i}':x.numpy() for i,x in enumerate(xs)})['y']
    results[name]=metric(actual,expected.numpy()); print(name,results[name],flush=True)
(ROOT/'ios/validation/flow/component-probes.json').write_text(json.dumps(results,indent=2)+'\n')
# Purpose: diagnose first-stage drift; upstream: pinned DiT modules; .venv-coreml local CPU.
# Generated 2026-09-29 America/New_York; new file, all lines added.
