# probe_symbolic_conditions.py
# Requirement: independently prove natural N=186/225 conditioning from a symbolic PyTorch graph, preserving all frozen assets and EOS semantics.
from __future__ import annotations
import argparse, ast, hashlib, json, logging, subprocess, sys, traceback
from pathlib import Path
from typing import Dict, Optional
import coremltools as ct
import numpy as np
import torch
from torch import nn
from torch.nn import functional as F

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'ios/tools'))
from reference_flow_conditions import load_reference_flow_conditioning
PIN = '878940245562bcd1dd0231d78157ba78d70b39f6'

def sha(path):
    h = hashlib.sha256()
    for f in sorted(path.rglob('*')) if path.is_dir() else [path]:
        if f.is_file():
            if path.is_dir(): h.update(str(f.relative_to(path)).encode())
            with f.open('rb') as stream:
                for b in iter(lambda: stream.read(8*1024*1024), b''): h.update(b)
    return h.hexdigest()

def metrics(expected, actual):
    a, b = np.asarray(expected, dtype=np.float64), np.asarray(actual, dtype=np.float64)
    if a.shape != b.shape: raise RuntimeError(f'shape mismatch {a.shape} != {b.shape}')
    d = a-b; denom = np.linalg.norm(a)*np.linalg.norm(b)
    return dict(shape=list(b.shape), finite=bool(np.isfinite(a).all() and np.isfinite(b).all()), maxAbsError=float(np.abs(d).max()), meanAbsError=float(np.abs(d).mean()), rmse=float(np.sqrt(np.mean(d*d))), cosineSimilarity=float(np.clip(np.sum(a*b)/denom,-1,1)) if denom else float(np.array_equal(a,b)), passTolerance=bool(np.isfinite(b).all() and np.all(np.abs(d)<=3e-4+3e-4*np.maximum(np.abs(a),np.abs(b)))))

def extract(source, relative, names, namespace):
    path = source / relative
    nodes = [n for n in ast.parse(path.read_text()).body if isinstance(n, (ast.ClassDef, ast.FunctionDef)) and n.name in names]
    if {n.name for n in nodes} != set(names): raise RuntimeError(f'upstream definitions missing {relative}')
    exec(compile(ast.Module(body=nodes, type_ignores=[]), str(path), 'exec'), namespace)

class Capture(nn.Module):
    def forward(self, mu, mask, spks, cond, **kwargs):
        self.values = (mu, spks, cond)
        return mu, None

def upstream_oracle(source, weights):
    ns = dict(torch=torch, nn=nn, F=F, Dict=Dict, Optional=Optional, logging=logging, DictConfig=dict, online_feature=False)
    extract(source, 'cosyvoice/utils/mask.py', ['make_pad_mask'], ns)
    extract(source, 'cosyvoice/transformer/upsample_encoder.py', ['PreLookaheadLayer'], ns)
    extract(source, 'cosyvoice/flow/flow.py', ['CausalMaskedDiffWithDiT'], ns)
    cap = Capture()
    flow = ns['CausalMaskedDiffWithDiT'](input_size=80, vocab_size=6561, token_mel_ratio=2, pre_lookahead_layer=ns['PreLookaheadLayer'](80,1024,3), decoder=cap).eval()
    state = {k:v for k,v in weights.items() if k.startswith(('input_embedding.','pre_lookahead_layer.','spk_embed_affine_layer.'))}
    flow.load_state_dict(state, strict=True)
    def run(inputs):
        tokens, prompt_tokens, prompt_feat, speaker = inputs
        flow.inference(tokens, torch.tensor([tokens.shape[1]]), prompt_tokens, torch.tensor([151]), prompt_feat, torch.tensor([302]), speaker, streaming=False, finalize=True)
        return tuple(torch.cat((v, v*0),dim=0) for v in cap.values)
    return run

class SymbolicConditions(nn.Module):
    def __init__(self, original):
        super().__init__()
        self.input_embedding = original.input_embedding
        self.pre_lookahead_layer = original.pre_lookahead_layer
        self.spk_embed_affine_layer = original.spk_embed_affine_layer
    def forward(self, tokens, prompt_tokens, prompt_feat, speaker):
        combined = torch.cat((prompt_tokens.long(), tokens.long()), dim=1)
        h = self.pre_lookahead_layer(self.input_embedding(combined.clamp(min=0)))
        h = h.repeat_interleave(2, dim=1).transpose(1,2)
        spks = self.spk_embed_affine_layer(F.normalize(speaker, dim=1))
        # Allocate exactly the upstream logical tail; no fake speech tokens or bucket padding.
        cond = torch.cat((prompt_feat.transpose(1,2), torch.zeros_like(h[:, :, prompt_feat.shape[1]:])), dim=2)
        return torch.cat((h,h*0),0), torch.cat((spks,spks*0),0), torch.cat((cond,cond*0),0)

def main():
    p=argparse.ArgumentParser(); p.add_argument('--source-root',type=Path,required=True); p.add_argument('--model-dir',type=Path,required=True); p.add_argument('--fixture',type=Path,required=True); p.add_argument('--output',type=Path,required=True); a=p.parse_args()
    a.output.mkdir(parents=True,exist_ok=False)
    receipt=dict(schemaVersion=1, status='RUNNING', phase='source', sourceCommit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(), pinnedUpstream=PIN, physicalDevice='NOT_RUN', tests=[], environment=dict(torch=torch.__version__,coremltools=ct.__version__), workloadProvenance='deterministic rebuild fixture target prefix; NOT real LLM workload tokens', productionDefaultFlowSteps=6)
    rp=a.output/'receipt.json'
    def save(): rp.write_text(json.dumps(receipt,indent=2)+'\n')
    save()
    try:
        if subprocess.check_output(['git','-C',str(a.source_root),'rev-parse','HEAD'],text=True).strip()!=PIN: raise RuntimeError('upstream pin mismatch')
        for rel in ['cosyvoice/flow/flow.py','cosyvoice/transformer/upsample_encoder.py','cosyvoice/utils/mask.py']:
            locked=subprocess.check_output(['git','-C',str(a.source_root),'show',f'{PIN}:{rel}'])
            if locked!=(a.source_root/rel).read_bytes(): raise RuntimeError(f'upstream source changed: {rel}')
        receipt['flowPtSha256']=sha(a.model_dir/'flow.pt')
        original=load_reference_flow_conditioning(a.model_dir/'flow.pt')
        wrapper=SymbolicConditions(original).eval()
        oracle=upstream_oracle(a.source_root,torch.load(a.model_dir/'flow.pt',weights_only=True,map_location='cpu',mmap=True))
        fixture=torch.load(a.fixture/'flow_input.pt',weights_only=True)['kwargs']
        def inputs(n): return (fixture['token'][:,:n].int(),fixture['prompt_token'].int(),fixture['prompt_feat'].float(),fixture['embedding'].float())
        names=('tokens','prompt_tokens','prompt_feat','speaker'); outputs=('mu','spks','cond')
        torch.set_num_threads(4)
        receipt['phase']='torch.export'; save()
        n=torch.export.Dim('speech_tokens',min=186,max=225)
        ep=torch.export.export(wrapper,inputs(225),dynamic_shapes=({1:n},{},{},{}),strict=False)
        if ep.dialect=='TRAINING': ep=ep.run_decompositions({})
        shapes={node.name:[str(d) for d in node.meta['val'].shape] for node in ep.graph.nodes if node.op=='placeholder' and isinstance(node.meta.get('val'),torch.Tensor)}
        token_node=next(node for node in ep.graph.nodes if node.op=='placeholder' and node.name=='tokens')
        if not isinstance(token_node.meta['val'].shape[1],torch.SymInt): raise RuntimeError('export materialized N')
        receipt['symbolicDimensionRetained']=True; receipt['rangeConstraints']={str(k):str(v) for k,v in ep.range_constraints.items()}; receipt['exportedShapes']=shapes
        (a.output/'exported_graph.txt').write_text(ep.graph_module.code)
        torch.export.save(ep,a.output/'conditions.pt2')
        for count in (186,225):
            sample=inputs(count)
            with torch.no_grad(): expected=oracle(sample); eager=wrapper(*sample); exported=ep.module()(*sample)
            row=dict(N=count,G=2*count,P=302,T=302+2*count,inputShapes={k:list(v.shape) for k,v in zip(names,sample)},eagerVsOfficial={k:metrics(e.numpy(),v.numpy()) for k,e,v in zip(outputs,expected,eager)},exportVsOfficial={k:metrics(e.numpy(),v.numpy()) for k,e,v in zip(outputs,expected,exported)})
            receipt['tests'].append(row)
            folder=a.output/f'N{count}'; folder.mkdir()
            for k,v in zip(names,sample): v.numpy().tofile(folder/f'{k}.bin')
            for k,v in zip(outputs,expected): v.numpy().tofile(folder/f'expected-{k}.bin')
        receipt['phase']='conversion'; save()
        rd=ct.RangeDim(186,225,default=225,symbol='speech_tokens')
        model=ct.convert(ep,source='pytorch',inputs=[ct.TensorType(name=k,shape=(1,rd) if k=='tokens' else tuple(v.shape),dtype=np.int32 if k in ('tokens','prompt_tokens') else np.float32) for k,v in zip(names,inputs(225))],outputs=[ct.TensorType(name=k,dtype=np.float32) for k in outputs],minimum_deployment_target=ct.target.iOS18,compute_precision=ct.precision.FLOAT32,convert_to='mlprogram',skip_model_load=True)
        package=a.output/'conditions.mlpackage'; model.save(str(package)); receipt['conversion']='PASS'; receipt['packageSha256']=sha(package)
        receipt['phase']='compilation'; save()
        subprocess.run(['xcrun','coremlcompiler','compile',str(package),str(a.output)],check=True); receipt['compilation']='PASS'
        receipt['phase']='loading'; save()
        model=ct.models.MLModel(str(package),compute_units=ct.ComputeUnit.CPU_ONLY); receipt['loading']='PASS'
        for row in receipt['tests']:
            receipt['phase']=f'prediction_N{row["N"]}'; save()
            sample=inputs(row['N'])
            with torch.no_grad(): expected=oracle(sample)
            predicted=model.predict({k:v.numpy() for k,v in zip(names,sample)})
            row['coremlCPUOnlyVsOfficial']={k:metrics(v.numpy(),predicted[k]) for k,v in zip(outputs,expected)}
            if not all(v['passTolerance'] for v in row['coremlCPUOnlyVsOfficial'].values()): raise RuntimeError('conditioning parity threshold failed')
            print('DYNAMIC_CONDITIONS '+json.dumps(row),flush=True)
        receipt['status']='PASS_HOST_SYMBOLIC_CONDITIONS'; receipt['phase']='complete'
    except Exception as e:
        receipt['status']='FAIL'; receipt['error']=str(e); receipt['exceptionType']=type(e).__name__; traceback.print_exc()
    finally: save(); print('RECEIPT '+str(rp),flush=True)
    return 0 if receipt['status'].startswith('PASS') else 1
if __name__=='__main__': raise SystemExit(main())
# Purpose: exact upstream conditioning interception, symbolic N export, serialized multi-length CPU parity and failure receipts.
# Upstream: pinned CosyVoice3_NPU@8789402 CausalMaskedDiffWithDiT.inference and PreLookaheadLayer; official flow.pt revision 29e01c4.
# Environment: isolated macOS Python 3.11, torch 2.7, coremltools 9; no Colab execution.
# Generated: 2026-10-03 America/New_York. New file; all lines independent of the frozen exporter/runtime.

# Changes 2026-10-03: line68 replaces symbolic F.pad with exact natural-T zero conditioning concatenation; attempt1 dynamic-pad conversion failure is retained.
