# llm_graphs.py
# Requirement: static CosyVoice3 Qwen prefill/decode graphs with explicit bounded KV tensors.
import json
from pathlib import Path
import torch
from torch import nn
from transformers import Qwen2Config
from transformers.models.qwen2.modeling_qwen2 import Qwen2DecoderLayer, Qwen2RMSNorm, Qwen2RotaryEmbedding

ROOT=Path(__file__).resolve().parents[2]
MODEL=ROOT/'pretrained_models/Fun-CosyVoice3-0.5B-2512'


def rotary(x,cos,sin):
    half=x.shape[-1]//2
    return x*cos+torch.cat((-x[...,half:],x[...,:half]),dim=-1)*sin


class SpeechLLM(nn.Module):
    def __init__(self,mode,capacity=512):
        super().__init__()
        self.config=Qwen2Config.from_dict(json.loads((MODEL/'CosyVoice-BlankEN/config.json').read_text()))
        self.config._attn_implementation='eager'
        self.layers=nn.ModuleList([Qwen2DecoderLayer(self.config,i) for i in range(self.config.num_hidden_layers)])
        self.norm=Qwen2RMSNorm(self.config.hidden_size,eps=self.config.rms_norm_eps)
        state=torch.load(MODEL/'llm.pt',weights_only=True,map_location='cpu',mmap=True)
        for i,layer in enumerate(self.layers):
            prefix=f'llm.model.model.layers.{i}.'
            layer.load_state_dict({k[len(prefix):]:v for k,v in state.items() if k.startswith(prefix)},strict=True)
        self.norm.weight.data.copy_(state['llm.model.model.norm.weight'])
        self.head=nn.Linear(self.config.hidden_size,state['llm_decoder.weight'].shape[0],bias=False)
        self.head.weight.data.copy_(state['llm_decoder.weight'])
        self.mode=mode; self.capacity=capacity
        self.heads=self.config.num_attention_heads; self.kvheads=self.config.num_key_value_heads
        self.dim=self.config.hidden_size//self.heads
        self.groups=self.heads//self.kvheads

    def forward(self,x,cos,sin,mask,keys,values,write_mask):
        newkeys=[]; newvalues=[]
        for i,layer in enumerate(self.layers):
            h=layer.input_layernorm(x); a=layer.self_attn
            q=a.q_proj(h).reshape(1,-1,self.heads,self.dim).transpose(1,2)
            k=a.k_proj(h).reshape(1,-1,self.kvheads,self.dim).transpose(1,2)
            v=a.v_proj(h).reshape(1,-1,self.kvheads,self.dim).transpose(1,2)
            q=rotary(q,cos,sin); k=rotary(k,cos,sin)
            if self.mode=='decode':
                k=keys[i]*(1-write_mask)+k*write_mask
                v=values[i]*(1-write_mask)+v*write_mask
            # Same grouped-query attention expansion as HF repeat_kv.
            n=k.shape[2]
            kr=k[:,:,None,:,:].expand(1,self.kvheads,self.groups,n,self.dim).reshape(1,self.heads,n,self.dim)
            vr=v[:,:,None,:,:].expand(1,self.kvheads,self.groups,n,self.dim).reshape(1,self.heads,n,self.dim)
            probs=torch.softmax(torch.matmul(q,kr.transpose(-1,-2))*(self.dim**-0.5)+mask,dim=-1)
            y=torch.matmul(probs,vr).transpose(1,2).reshape(1,-1,self.config.hidden_size)
            x=x+a.o_proj(y)
            x=x+layer.mlp(layer.post_attention_layernorm(x))
            if self.mode=='prefill':
                k=torch.nn.functional.pad(k,(0,0,0,self.capacity-k.shape[2]))
                v=torch.nn.functional.pad(v,(0,0,0,self.capacity-v.shape[2]))
            newkeys.append(k); newvalues.append(v)
        hidden=self.norm(x)[:,-1,:]
        return self.head(hidden),torch.stack(newkeys),torch.stack(newvalues),hidden


def rope(config,positions):
    module=Qwen2RotaryEmbedding(config)
    c,s=module(torch.zeros(1,len(positions),config.hidden_size),torch.tensor([positions]))
    return c.unsqueeze(1),s.unsqueeze(1)


def inputs(model,fixture,mode):
    record=torch.load(fixture/f'llm_step_{0 if mode=="prefill" else 1:03d}_input.pt',weights_only=True)
    x=record['args'][0]; capacity=model.capacity
    keys=torch.zeros(len(model.layers),1,model.kvheads,capacity,model.dim)
    values=torch.zeros_like(keys); write=torch.zeros(1,1,capacity,1)
    if mode=='prefill':
        n=x.shape[1]; c,s=rope(model.config,list(range(n)))
        mask=torch.full((1,1,n,n),torch.finfo(torch.float32).min).triu(1)
    else:
        cache=record['kwargs']['cache']; n=cache[0][0].shape[2]
        for i,(k,v) in enumerate(cache): keys[i,:,:,:n]=k; values[i,:,:,:n]=v
        c,s=rope(model.config,[n]); write[:,:,n,:]=1
        mask=torch.full((1,1,1,capacity),torch.finfo(torch.float32).min); mask[:,:,:,:n+1]=0
    return x,c,s,mask,keys,values,write
# Purpose: decompose official Qwen neural steps; upstream: transformers 4.51.3 Qwen2 + CosyVoice3LM.
# Environment: .venv-coreml, FP32 parity before conversion; generated 2026-09-29 America/New_York; new file.
