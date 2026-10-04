# probe_symbolic_shard0.py
# Requirement: prove only the first four official DiT blocks at symbolic natural T674/T752, with exact upstream and serialized Core ML parity receipts.
from __future__ import annotations
import argparse, json, subprocess, sys, traceback
from pathlib import Path
import coremltools as ct
import numpy as np
import torch
import yaml
from torch import nn
from probe_symbolic_conditions import ROOT, PIN, SymbolicConditions, extract, sha, metrics
sys.path.insert(0,str(ROOT/'ios/tools'))
from reference_flow_conditions import load_reference_flow_conditioning

def main():
    p=argparse.ArgumentParser(); p.add_argument('--source-root',type=Path,required=True); p.add_argument('--model-dir',type=Path,required=True); p.add_argument('--fixture',type=Path,required=True); p.add_argument('--conditions-receipt',type=Path,required=True); p.add_argument('--output',type=Path,required=True); p.add_argument('--precision',choices=['fp16','fp32'],default='fp16'); p.add_argument('--materialize-static-reshape-dims',action='store_true'); a=p.parse_args()
    a.output.mkdir(parents=True,exist_ok=False)
    receipt=dict(schemaVersion=1,status='RUNNING',phase='source',sourceCommit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),pinnedUpstream=PIN,physicalDevice='NOT_RUN',tests=[],precision=a.precision+' internal, FP32 boundaries',workloadProvenance='deterministic rebuild fixture target prefix; NOT real LLM workload tokens',environment=dict(torch=torch.__version__,coremltools=ct.__version__))
    receipt['exporterSha256']=sha(Path(__file__))
    receipt['oracleHelperSha256']=sha(Path(__file__).parent/'probe_symbolic_conditions.py')
    receipt['sourceDirty']=bool(subprocess.check_output(['git','status','--porcelain','--untracked-files=normal'],cwd=ROOT,text=True).strip())
    receipt['fixtureFlowInputSha256']=sha(a.fixture/'flow_input.pt')
    rp=a.output/'receipt.json'
    def save(): rp.write_text(json.dumps(receipt,indent=2)+'\n')
    save()
    try:
        gate=json.loads(a.conditions_receipt.read_text())
        if gate['status']!='PASS_HOST_SYMBOLIC_CONDITIONS' or not gate['symbolicDimensionRetained']: raise RuntimeError('Phase1A gate missing')
        if subprocess.check_output(['git','-C',str(a.source_root),'rev-parse','HEAD'],text=True).strip()!=PIN: raise RuntimeError('upstream pin mismatch')
        for rel in ['cosyvoice/flow/DiT/dit.py','cosyvoice/flow/DiT/modules.py','iOS/tools/export_flow_fp16_shards.py']:
            if subprocess.check_output(['git','-C',str(a.source_root),'show',f'{PIN}:{rel}'])!=(a.source_root/rel).read_bytes(): raise RuntimeError(f'upstream blob mismatch {rel}')
        sys.path.insert(0,str(a.source_root.resolve()))
        from cosyvoice.flow.DiT.dit import DiT
        config=yaml.load((a.model_dir/'cosyvoice3.yaml').read_text(),Loader=yaml.BaseLoader)['flow']['decoder']['estimator']
        keys=('dim','depth','heads','dim_head','ff_mult','mel_dim','mu_dim','spk_dim','out_channels')
        estimator=DiT(**{k:int(config[k]) for k in keys},static_chunk_size=50,num_decoding_left_chunks=-1).eval()
        weights=torch.load(a.model_dir/'flow.pt',weights_only=True,map_location='cpu',mmap=True)
        estimator.load_state_dict({k[len('decoder.estimator.'):]:v for k,v in weights.items() if k.startswith('decoder.estimator.')},strict=True)
        receipt['flowPtSha256']=sha(a.model_dir/'flow.pt')
        ns=dict(nn=nn)
        extract(a.source_root,'iOS/tools/export_flow_fp16_shards.py',['FirstShard'],ns)
        shard=ns['FirstShard'](estimator,0,4).eval()
        conditioning=SymbolicConditions(load_reference_flow_conditioning(a.model_dir/'flow.pt')).eval()
        fixture=torch.load(a.fixture/'flow_input.pt',weights_only=True)['kwargs']
        frozen=torch.load(a.fixture/'estimator_00.pt',weights_only=True)['args']
        def inputs(n):
            total=302+2*n
            with torch.no_grad(): mu,spks,cond=conditioning(fixture['token'][:,:n].int(),fixture['prompt_token'].int(),fixture['prompt_feat'],fixture['embedding'])
            # Exact first-call upstream noise prefix; no output/bucket padding.
            return (frozen[0][:,:,:total].contiguous(),torch.ones(2,1,total),mu,torch.zeros(2),spks,cond)
        observed={}
        hooks=[estimator.transformer_blocks[3].register_forward_hook(lambda m,i,o:observed.update(h=o.detach().clone())),estimator.time_embed.register_forward_hook(lambda m,i,o:observed.update(te=o.detach().clone()))]
        def oracle(sample):
            with torch.no_grad(): estimator(*sample,streaming=False)
            return observed['h'],observed['te']
        torch.set_num_threads(4)
        names=('x','mask','mu','t','spks','cond'); outputs=('h','te')
        receipt['phase']='torch.export'; save()
        t=torch.export.Dim('flow_frames',min=674,max=752)
        ep=torch.export.export(shard,inputs(225),dynamic_shapes=({2:t},{2:t},{2:t},{},{},{2:t}),strict=False)
        if ep.dialect=='TRAINING': ep=ep.run_decompositions({})
        changes=[]
        if a.materialize_static_reshape_dims:
            for node in ep.graph.nodes:
                if node.op=='call_function' and str(node.target) in {'aten.view.default','aten.reshape.default','aten._unsafe_view.default'}:
                    shape=list(node.args[1]); meta=node.meta.get('val')
                    if meta is None or len(shape)!=len(meta.shape): continue
                    for axis,v in enumerate(shape):
                        proven=meta.shape[axis]
                        if type(v) is int and v==-1 and type(proven) is int and proven>0:
                            shape[axis]=proven; changes.append(dict(node=node.name,axis=axis,before=-1,after=proven))
                    node.args=(node.args[0],shape,*node.args[2:])
            ep.graph.lint(); ep.graph_module.recompile(); ep.validate()
        receipt['staticReshapeRewrites']=changes
        placeholder=next(n for n in ep.graph.nodes if n.op=='placeholder' and n.name=='x')
        if not isinstance(placeholder.meta['val'].shape[2],torch.SymInt): raise RuntimeError('source T not symbolic')
        receipt['symbolicDimensionRetained']=True; receipt['rangeConstraints']={str(k):str(v) for k,v in ep.range_constraints.items()}
        (a.output/'exported_graph.txt').write_text(ep.graph_module.code); torch.export.save(ep,a.output/'shard0.pt2')
        for count in (186,225):
            sample=inputs(count); expected=oracle(sample)
            with torch.no_grad(): eager=shard(*sample); exported=ep.module()(*sample)
            row=dict(N=count,G=2*count,P=302,T=302+2*count,inputShapes={k:list(v.shape) for k,v in zip(names,sample)},eagerVsOfficial={k:metrics(e.numpy(),v.numpy()) for k,e,v in zip(outputs,expected,eager)},exportVsOfficial={k:metrics(e.numpy(),v.numpy()) for k,e,v in zip(outputs,expected,exported)})
            receipt['tests'].append(row)
            folder=a.output/f'N{count}'; folder.mkdir()
            for k,v in zip(names,sample): v.numpy().tofile(folder/f'{k}.bin')
            for k,v in zip(outputs,expected): v.numpy().tofile(folder/f'expected-{k}.bin')
        for h in hooks: h.remove()
        receipt['phase']='conversion'; save()
        rd=ct.RangeDim(674,752,default=752,symbol='flow_frames')
        types=[ct.TensorType(name=k,shape=tuple(rd if axis==2 and k in ('x','mask','mu','cond') else d for axis,d in enumerate(v.shape)),dtype=np.float32) for k,v in zip(names,inputs(225))]
        model=ct.convert(ep,source='pytorch',inputs=types,outputs=[ct.TensorType(name=k,dtype=np.float32) for k in outputs],minimum_deployment_target=ct.target.iOS18,compute_precision=ct.precision.FLOAT16 if a.precision=='fp16' else ct.precision.FLOAT32,convert_to='mlprogram',skip_model_load=True)
        package=a.output/'shard0.mlpackage'; model.save(str(package)); receipt['conversion']='PASS'; receipt['packageSha256']=sha(package)
        receipt['phase']='compilation'; save(); subprocess.run(['xcrun','coremlcompiler','compile',str(package),str(a.output)],check=True); receipt['compilation']='PASS'
        receipt['phase']='loading'; save(); model=ct.models.MLModel(str(package),compute_units=ct.ComputeUnit.CPU_ONLY); receipt['loading']='PASS'
        for row in receipt['tests']:
            receipt['phase']=f'prediction_N{row["N"]}'; save(); sample=inputs(row['N'])
            predicted=model.predict({k:v.numpy() for k,v in zip(names,sample)})
            folder=a.output/f'N{row["N"]}'
            row['coremlCPUOnlyVsOfficial']={k:metrics(np.fromfile(folder/f'expected-{k}.bin',np.float32).reshape(predicted[k].shape),predicted[k]) for k in outputs}
            # Record FP16 drift without inventing a new accepted tolerance.
            row['finite']=all(v['finite'] for v in row['coremlCPUOnlyVsOfficial'].values())
            print('DYNAMIC_SHARD0 '+json.dumps(row),flush=True)
            if not row['finite']: raise RuntimeError('nonfinite shard0')
        receipt['status']='HOST_SYMBOLIC_SHARD0_NUMERICS_RECORDED_NOT_ACCEPTED'; receipt['phase']='complete'
    except Exception as e:
        receipt['status']='FAIL'; receipt['error']=str(e); receipt['exceptionType']=type(e).__name__; traceback.print_exc()
    finally: save(); print('RECEIPT '+str(rp),flush=True)
    return 0 if receipt['status'].startswith('HOST') else 1
if __name__=='__main__': raise SystemExit(main())
# Purpose: first DiT risk probe with symbolic T, exact official four-block oracle and multi-length CPU/device fixture boundary.
# Upstream: CosyVoice3_NPU@8789402 FirstShard/DiT and official flow.pt revision29e01c4. No math approximation.
# Environment: isolated macOS torch2.7/coremltools9/Python3.11. Generated: 2026-10-03 America/New_York.
# New file, all lines. Does not export shards1-5 or change shipping runtime/cap.

# Changes 2026-10-03: line15 and conversion allow an independent FP32 control to isolate precision from symbolic-shape lowering; no Flow math changes.

# Changes 2026-10-03: record exporter/oracle-helper/fixture SHA256 and working-tree dirtiness before export for exact experimental provenance.
