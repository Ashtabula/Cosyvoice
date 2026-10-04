# export_full_range_family.py
# Requirement: export one experiment-only true-symbolic acoustic family for a caller-selected lower bound through the fixed512-derived N=479 upper envelope, while preserving frozen fixed225 assets and all prior evidence.
from __future__ import annotations
import argparse,gc,json,subprocess,traceback
from pathlib import Path
import numpy as np
import torch
import coremltools as ct
from torch.nn import functional as F
from probe_symbolic_conditions import ROOT,PIN,SymbolicConditions,sha
from run_phase2_dynamic_flow import load_estimator,load_shards,source_first_call,load_full_graph,load_reference_flow_conditioning,export_package
from run_phase3_dynamic_hift import load_hift,DynamicHiFTBody,host_phase,export_dynamic_body
from run_shard0_attribution import metrics

BASE=ROOT/'ios/.work/rebuild/ios-fixed225-reference'
DEFAULT_N_MIN=3
DEFAULT_N_MAX=479
P=302
UPSAMPLE=480

def save_json(path,value):
    path.write_text(json.dumps(value,indent=2,sort_keys=True)+'\n')

def target_tokens(n:int):
    return torch.zeros((1,n),dtype=torch.int32)

def flow_case(n:int,conditioning,fixture):
    tokens=target_tokens(n)
    with torch.no_grad():
        mu,spks,cond=conditioning(tokens,fixture['prompt_token'].int(),fixture['prompt_feat'].float(),fixture['embedding'].float())
    t=P+2*n
    return {'N':n,'G':2*n,'P':P,'T':t,'mu':mu,'spks':spks,'cond':cond,
            'noise':torch.zeros((1,80,t),dtype=mu.dtype),'mask':torch.ones((2,1,t),dtype=mu.dtype)}

def norm_buffer(samples:int):
    window=torch.hann_window(16,periodic=True,dtype=torch.float64)
    norm=F.conv_transpose1d(torch.ones((1,1,samples//4+1),dtype=torch.float32),
                            window.float().square()[None,None],stride=4)[:,:,8:-8].contiguous()
    if tuple(norm.shape)!=(1,1,samples):raise RuntimeError(f'norm shape mismatch: {tuple(norm.shape)}')
    return norm

def hift_example(body,frames:int):
    samples=frames*UPSAMPLE
    mel=torch.linspace(-0.25,0.25,steps=80*frames,dtype=torch.float32).reshape(1,80,frames).contiguous()
    f0=torch.full((1,frames),120.0,dtype=torch.float32)
    phase=host_phase(f0).float().contiguous()
    noise=torch.zeros((1,samples,9),dtype=torch.float32)
    norm=norm_buffer(samples)
    with torch.no_grad():pcm=body(mel,f0,phase,noise,norm)
    if tuple(pcm.shape)!=(1,samples) or not bool(torch.isfinite(pcm).all()):
        raise RuntimeError(f'HiFT synthetic source execution failed at G={frames}: {tuple(pcm.shape)}')
    return (mel,f0,phase,noise,norm),pcm

def main():
    p=argparse.ArgumentParser()
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--n-min',type=int,default=DEFAULT_N_MIN)
    p.add_argument('--n-max',type=int,default=DEFAULT_N_MAX)
    a=p.parse_args()
    if not (1 <= a.n_min <= a.n_max <= 479):
        raise SystemExit(f'invalid bounds N={a.n_min}...{a.n_max}; expected 1 <= min <= max <= 479')
    n_min,n_max=a.n_min,a.n_max
    checkpoint_candidates=[n_min,2,3,225,256,320,384,448,n_max]
    checkpoints=[]
    for value in checkpoint_candidates:
        if n_min <= value <= n_max and value not in checkpoints: checkpoints.append(value)
    a.output.mkdir(parents=True,exist_ok=False)
    source=BASE/'source';model=BASE/'model-cache/Fun-CosyVoice3-0.5B-2512';fixture_root=BASE/'fixture'
    r={'schemaVersion':1,'status':'RUNNING','sourceCommit':subprocess.check_output(['git','-C',str(ROOT),'rev-parse','HEAD'],text=True).strip(),
       'pinnedUpstream':PIN,'productionPromotion':False,
       'generationContract':'per request maxN=min(targetTextTokens*20,512-logicalPrefixLength); reference/prompt/target all contribute to logicalPrefixLength',
       'globalAcousticEnvelope':[n_min,n_max],'NBounds':[n_min,n_max],
       'TBounds':[P+2*n_min,P+2*n_max],'GBounds':[2*n_min,2*n_max],
       'checkpoints':list(checkpoints),'syntheticShapeInputs':True,'packages':[]}
    rp=a.output/'receipt.json'
    def save():save_json(rp,r)
    save()
    try:
        torch.set_num_threads(4)
        fixture=torch.load(fixture_root/'flow_input.pt',weights_only=True)['kwargs']
        conditioning=SymbolicConditions(load_reference_flow_conditioning(model/'flow.pt')).eval()

        r['phase']='conditions_source';save()
        example=(target_tokens(n_max),fixture['prompt_token'].int(),fixture['prompt_feat'].float(),fixture['embedding'].float())
        n=torch.export.Dim('speech_tokens',min=n_min,max=n_max)
        ep=torch.export.export(conditioning,example,dynamic_shapes=({1:n},{},{},{}),strict=False)
        if ep.dialect=='TRAINING':ep=ep.run_decompositions({})
        node=next(v for v in ep.graph.nodes if v.op=='placeholder' and v.name=='tokens')
        if not isinstance(node.meta['val'].shape[1],torch.SymInt):raise RuntimeError('conditions N materialized')
        folder=a.output/'conditions';folder.mkdir()
        torch.export.save(ep,folder/'source.pt2')
        rd=ct.RangeDim(n_min,n_max,default=n_max,symbol='speech_tokens')
        names=('tokens','prompt_tokens','prompt_feat','speaker')
        converted=ct.convert(ep,source='pytorch',
            inputs=[ct.TensorType(name=k,shape=(1,rd) if k=='tokens' else tuple(v.shape),dtype=np.int32 if k in ('tokens','prompt_tokens') else np.float32) for k,v in zip(names,example)],
            outputs=[ct.TensorType(name=k,dtype=np.float32) for k in ('mu','spks','cond')],
            convert_to='mlprogram',minimum_deployment_target=ct.target.iOS18,compute_precision=ct.precision.FLOAT32,skip_model_load=True)
        package=folder/'conditions.mlpackage';converted.save(str(package))
        compiled=folder/'compiled';compiled.mkdir();subprocess.run(['xcrun','coremlcompiler','compile',str(package),str(compiled)],check=True)
        r['conditions']={'path':str(package),'sha256':sha(package),'range':[n_min,n_max]};save()

        r['phase']='flow_source';save()
        estimator=load_estimator(source,model);full=load_full_graph(source,estimator);shards=load_shards(source,estimator)
        case=flow_case(n_max,conditioning,fixture)
        arguments,official,sharded,boundaries=source_first_call(full,shards,case)
        r[f'sourceSixShardVsFullAtN{n_max}']=metrics(official.numpy(),sharded.numpy());save()
        h,te=shards[0](*arguments);examples=[arguments]
        for i in range(1,6):
            examples.append((h.detach().contiguous(),te.detach().contiguous(),case['mask'].detach().contiguous()))
            if i<5:
                with torch.no_grad():h=shards[i](*examples[-1])
        for i,shard in enumerate(shards):
            r['phase']=f'flow_export_{i}';save()
            result=export_package(shard,i,examples[i],a.output/'packages',ct.precision.FLOAT16,frame_bounds=tuple(r['TBounds']))
            r['packages'].append({k:v for k,v in result.items() if k!='package'});save()
        del estimator,full,shards,conditioning,examples,h,te;gc.collect()

        r['phase']='hift_source';save()
        hift_folder=a.output/'hift';hift_folder.mkdir()
        hift,_=load_hift(source,model,hift_folder);body=DynamicHiFTBody(hift).eval()
        example,pcm=hift_example(body,2*n_max)
        r[f'sourceHiFTAtG{2*n_max}']={'pcmShape':list(pcm.shape),'finite':bool(torch.isfinite(pcm).all())};save()
        result=export_dynamic_body(body,example,hift_folder,r,save,frames=tuple(r['GBounds']))
        r['hift']={k:v for k,v in result.items() if k!='package'}
        r['status']='PASS_FULL_RANGE_SYMBOLIC_FAMILY_EXPORT_NOT_PROMOTED';r['phase']='complete'
    except Exception as e:
        r.update(status='FAIL',error=str(e),traceback=traceback.format_exc())
    save();print(json.dumps(r,indent=2),flush=True)
    return 0 if r['status'].startswith('PASS_') else 1

if __name__=='__main__':raise SystemExit(main())

# Code purpose: export true symbolic Conditions/Flow/HiFT for caller-selected Nmin...Nmax within the fixed512-derived N<=479 envelope; default remains N3...479 and lower-bound extension can request N1...479.
# Upstream source: pinned CosyVoice3 acoustic math plus previously accepted dynamic exporters; fixed225 release assets remain read-only controls.
# Runtime environment: macOS arm64 Python3.11/torch2.7/coremltools9 and Xcode coremlcompiler.
# Generated time: 2026-10-04 America/New_York.
# Changes: new full-envelope experiment; synthetic deterministic shape inputs remove all N225 fixture-length assumptions; no production promotion.

# Changes 2026-10-04: add --n-min/--n-max; default remains 3...479. N1 lower-bound experiments reuse the exact exporter/math and only widen the declared symbolic lower ranges. Checkpoints are generated from bounds.
