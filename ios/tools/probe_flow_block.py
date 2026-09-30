# probe_flow_block.py
# Requirement: locate DiT attention/normalization drift against the official first block.
import json,sys
import torch,numpy as np,coremltools as ct
from llm_graphs import ROOT,MODEL
from export_llm import metric
sys.path.insert(0,str(ROOT))
from cosyvoice.flow.DiT.dit import DiT

torch.set_num_threads(4)
m=DiT(dim=1024,depth=22,heads=16,dim_head=64,ff_mult=2,mel_dim=80,mu_dim=80,spk_dim=80,out_channels=80,static_chunk_size=50,num_decoding_left_chunks=-1).eval()
s=torch.load(MODEL/'flow.pt',weights_only=True,map_location='cpu',mmap=True)
m.load_state_dict({k[len('decoder.estimator.'):]:v for k,v in s.items() if k.startswith('decoder.estimator.')})
r=torch.load(ROOT/'ios/validation/phase0/run-002/tensors/estimator_08.pt',weights_only=True)['args']
with torch.no_grad():
    x=m.input_embed(r[0].transpose(1,2),r[5].transpose(1,2),r[2].transpose(1,2),r[4]); t=m.time_embed(r[3])
class Block(torch.nn.Module):
    def __init__(self):
        super().__init__(); self.b=m.transformer_blocks[0]; self.rot=m.rotary_embed
    def forward(self,x,t):
        norm,gate,shift,scale,gateff=self.b.attn_norm(x,emb=t)
        att=self.b.attn(x=norm,mask=torch.ones(2,1,752,752,dtype=torch.bool),rope=self.rot.forward_from_seq_len(752))
        mid=x+gate.unsqueeze(1)*att
        normalized=self.b.ff_norm(mid)
        ffinput=normalized*(1+scale[:,None])+shift[:,None]
        ff=self.b.ff(ffinput)
        return norm,att,normalized,ffinput,ff,mid+gateff.unsqueeze(1)*ff
b=Block().eval()
with torch.no_grad(): expected=b(x,t); trace=torch.jit.trace(b,(x,t),check_trace=False)
names=['norm','att','normalized','ffinput','ff','out']
c=ct.convert(trace,inputs=[ct.TensorType(name='x',shape=x.shape),ct.TensorType(name='t',shape=t.shape)],outputs=[ct.TensorType(name=n) for n in names],compute_precision=ct.precision.FLOAT32,compute_units=ct.ComputeUnit.CPU_ONLY,minimum_deployment_target=ct.target.iOS17)
a=c.predict({'x':x.numpy(),'t':t.numpy()})
result={n:metric(a[n],e.numpy()) for n,e in zip(names,expected)}
(ROOT/'ios/validation/flow/block-probes.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result,indent=2))
# Purpose: localize numerical error; upstream: official DiTBlock; .venv-coreml CPU.
# Generated 2026-09-29 America/New_York; new file, all lines added.
