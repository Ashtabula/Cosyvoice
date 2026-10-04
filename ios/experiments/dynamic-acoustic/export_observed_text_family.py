# export_observed_text_family.py
# Requirement: re-export one genuine symbolic family covering actual native early-EOS counts plus original controls, never pad or widen metadata only.
import argparse,json,subprocess,traceback,gc
from pathlib import Path
import numpy as np
import torch
import coremltools as ct
from probe_symbolic_conditions import ROOT,PIN,SymbolicConditions,sha
from run_phase2_dynamic_flow import load_estimator,load_shards,source_first_call,load_full_graph,natural_inputs,load_reference_flow_conditioning,export_package
from run_phase3_dynamic_hift import load_hift,DynamicHiFTBody,source_cases,load_fixed_oracle_class,mel_fixture,export_dynamic_body
import run_phase3_dynamic_hift as hift_module
BASE=ROOT/'ios/.work/rebuild/ios-fixed225-reference'

def main():
    p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--text-traces',type=Path,required=True);a=p.parse_args()
    a.output.mkdir(parents=True,exist_ok=False)
    traces=[json.loads(f.read_text()) for f in sorted(a.text_traces.glob('text-*.json'))]
    if not traces or not all(t['actualEarlyEOS'] and t['stopToken']==6562 for t in traces):raise RuntimeError('Missing real EOS evidence')
    counts=sorted(set([186,225]+[t['N'] for t in traces]));lo,hi=min(counts),max(counts)
    source=BASE/'source';model=BASE/'model-cache/Fun-CosyVoice3-0.5B-2512';fixture=BASE/'fixture'
    r={'status':'RUNNING','sourceCommit':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),'pinnedUpstream':PIN,
       'counts':counts,'NBounds':[lo,hi],'TBounds':[302+2*lo,302+2*hi],'GBounds':[2*lo,2*hi],'productionPromotion':False,'packages':[]}
    def save():(a.output/'receipt.json').write_text(json.dumps(r,indent=2,sort_keys=True)+'\n')
    save()
    try:
        torch.set_num_threads(4)
        flow_fixture=torch.load(fixture/'flow_input.pt',weights_only=True)['kwargs']
        args0=torch.load(fixture/'estimator_00.pt',weights_only=True)['args']
        conditioning=SymbolicConditions(load_reference_flow_conditioning(model/'flow.pt')).eval()
        example=(flow_fixture['token'][:,:hi].int(),flow_fixture['prompt_token'].int(),flow_fixture['prompt_feat'].float(),flow_fixture['embedding'].float())
        r['phase']='conditions_export';save()
        n=torch.export.Dim('speech_tokens',min=lo,max=hi)
        ep=torch.export.export(conditioning,example,dynamic_shapes=({1:n},{},{},{}),strict=False)
        if ep.dialect=='TRAINING':ep=ep.run_decompositions({})
        folder=a.output/'conditions';folder.mkdir();torch.export.save(ep,folder/'source.pt2')
        node=next(v for v in ep.graph.nodes if v.op=='placeholder' and v.name=='tokens')
        if not isinstance(node.meta['val'].shape[1],torch.SymInt):raise RuntimeError('Conditions N materialized')
        rd=ct.RangeDim(lo,hi,default=hi,symbol='speech_tokens');names=('tokens','prompt_tokens','prompt_feat','speaker')
        m=ct.convert(ep,source='pytorch',inputs=[ct.TensorType(name=k,shape=(1,rd) if k=='tokens' else tuple(v.shape),dtype=np.int32 if k in names[:2] else np.float32) for k,v in zip(names,example)],outputs=[ct.TensorType(name=k,dtype=np.float32) for k in ('mu','spks','cond')],convert_to='mlprogram',minimum_deployment_target=ct.target.iOS18,compute_precision=ct.precision.FLOAT32,skip_model_load=True)
        package=folder/'conditions.mlpackage';m.save(str(package));subprocess.run(['xcrun','coremlcompiler','compile',str(package),str(folder)],check=True)
        r['conditionsSha256']=sha(package);save()
        estimator=load_estimator(source,model);full=load_full_graph(source,estimator);shards=load_shards(source,estimator)
        case=natural_inputs(hi,conditioning,flow_fixture,args0)
        arguments,official,sharded,boundaries=source_first_call(full,shards,case)
        from run_shard0_attribution import metrics
        r['sourceSixShardVsFull']=metrics(official.numpy(),sharded.numpy());save()
        h,te=shards[0](*arguments)
        examples=[arguments]
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
        folder=a.output/'hift';folder.mkdir()
        hift,_=load_hift(source,model,folder);body=DynamicHiFTBody(hift).eval()
        hift_module.FRAMES=tuple(r['GBounds'])
        cases=source_cases(hift,load_fixed_oracle_class(source),body,mel_fixture(fixture))
        r['sourceHiFTTests']={str(g):c['sourceDynamicVsFixed'] for g,c in cases.items()};save()
        c=cases[max(cases)];example=tuple(c[k] for k in ('mel','f0','phase','noise','norm'))
        result=export_dynamic_body(body,example,folder,r,save,frames=tuple(r['GBounds']))
        r['hift']={k:v for k,v in result.items() if k!='package'}
        r['status']='PASS_OBSERVED_TEXT_SYMBOLIC_FAMILY_EXPORT_NOT_PROMOTED';r['phase']='complete'
    except Exception as e:r.update(status='FAIL',error=str(e),traceback=traceback.format_exc())
    save();print(json.dumps(r,indent=2));return 0 if r['status'].startswith('PASS') else 1
if __name__=='__main__':raise SystemExit(main())
# Purpose: export unified N observed..225, T302+2N, G2N family using unchanged model math.
# Upstream: pinned CosyVoice3 and existing Phase2/3 exporters. Environment: macOS Python3.11/CoreMLTools9.
# Generated: 2026-10-04 America/New_York. New file, all lines; old artifacts/receipts/cap remain unchanged.
