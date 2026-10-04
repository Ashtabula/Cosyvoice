# run_dynamic_acoustic_host.py
# Requirement: integrate actual six-step dynamic Flow mel with FP64 F0, host phase and one dynamic HiFT package; preserve frozen controls and component gates.
from __future__ import annotations
import argparse, gc, json, subprocess, sys, traceback
from pathlib import Path
import numpy as np
import torch
import coremltools as ct
from probe_symbolic_conditions import ROOT, PIN, SymbolicConditions, sha
from run_shard0_attribution import metrics
from run_phase2_dynamic_flow import (load_estimator, load_full_graph, natural_inputs,
    source_rollout, coreml_rollout, to_coreml_case, load_fixed, frozen_rollout,
    fixed_conditions_feed, load_reference_flow_conditioning)
from run_phase3_dynamic_hift import (load_hift, DynamicHiFTBody, load_fixed_oracle_class,
    frame_buffers, host_phase, fixed_asset_hift)

EXP = Path(__file__).parent
BASE = ROOT / 'ios/.work/rebuild/ios-fixed225-reference'
SOURCE = BASE / 'source'
MODEL = BASE / 'model-cache/Fun-CosyVoice3-0.5B-2512'
FIXTURE = BASE / 'fixture'
FIXED = ROOT / 'ios/.work/production-clean-room/fetched-runtime'
FLOW = ROOT / 'ios/.work/dynamic-acoustic/phase2-dynamic-flow-v4/packages'
HIFT = ROOT / 'ios/.work/dynamic-acoustic/phase3-dynamic-hift-v7/hift-dynamic-body-fp32.mlpackage'
COND = ROOT / 'ios/.work/dynamic-acoustic/conditions-final/conditions.mlpackage'
COUNTS = (186,225)
TRACES = {}


def save_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')


def source_flow(work):
    torch.set_num_threads(4)
    estimator = load_estimator(SOURCE, MODEL)
    full = load_full_graph(SOURCE, estimator)
    conditioning = SymbolicConditions(load_reference_flow_conditioning(MODEL/'flow.pt')).eval()
    fixture = torch.load(FIXTURE/'flow_input.pt', weights_only=True)['kwargs']
    args0 = torch.load(FIXTURE/'estimator_00.pt', weights_only=True)['args']
    for n in COUNTS:
        current=dict(fixture)
        if n in TRACES: current["token"]=torch.tensor([TRACES[n]["speechTokens"]],dtype=torch.int32)
        case = natural_inputs(n, conditioning, current, args0)
        state = source_rollout(full, case)
        values = to_coreml_case(case)
        feed = fixed_conditions_feed(current)
        feed['tokens'] = feed['tokens'][:,:n].copy()
        values.update({f'input_{k}':v for k,v in feed.items()})
        values['source_mel'] = state.detach().numpy()[:,:,302:].copy()
        np.savez(work/f'flow-N{n}.npz', **values)
        print(f'[DYNAMIC-HOST] source Flow N{n} complete', flush=True)


def flow_host(work):
    models = [ct.models.MLModel(str(FLOW/f'shard-{i:02d}/flow-shard.mlpackage'), compute_units=ct.ComputeUnit.CPU_ONLY) for i in range(6)]
    conditions = ct.models.MLModel(str(COND), compute_units=ct.ComputeUnit.CPU_ONLY)
    _, fixed_cond, fixed_shards = load_fixed(FIXED)
    fixed_conditions = ct.models.MLModel(str(fixed_cond), compute_units=ct.ComputeUnit.CPU_ONLY)
    fixed_models = [ct.models.MLModel(str(p), compute_units=ct.ComputeUnit.CPU_ONLY) for p in fixed_shards]
    rows=[]
    for n in COUNTS:
        values = dict(np.load(work/f'flow-N{n}.npz'))
        feed={k:values[f'input_{k}'] for k in ('tokens','prompt_tokens','prompt_feat','speaker')}
        result = conditions.predict(feed)
        condition_metrics = {k:metrics(values[k],result[k]) for k in ('mu','spks','cond')}
        case={k:values[k] for k in ('noise','mask')}
        case.update({k:result[k] for k in ('mu','spks','cond')})
        state=coreml_rollout(models,case)
        dynamic_mel=state[:,:,302:].copy()
        np.save(work/f'dynamic-mel-N{n}.npy',dynamic_mel)
        row={'N':n,'T':302+2*n,'G':2*n,'samples':960*n,
             'conditionsVsSource':condition_metrics,'dynamicMelVsSource':metrics(values['source_mel'],dynamic_mel)}
        for k,v in case.items(): np.save(work/f'case-N{n}-{k}.npy',v)
        if n==225:
            frozen=frozen_rollout(fixed_conditions,fixed_models,feed,case['noise'])[:,:,302:].copy()
            np.save(work/f'frozen-mel-N{n}.npy',frozen)
            row['frozenMelVsSource']=metrics(values['source_mel'],frozen)
            row['dynamicMelVsFrozen']=metrics(frozen,dynamic_mel)
        rows.append(row)
        save_json(work/'flow-results.json',rows)
        print(f'[DYNAMIC-HOST] actual dynamic Flow N{n} mel={dynamic_mel.shape}',flush=True)


def source_hift(work):
    torch.set_num_threads(4)
    hift, config=load_hift(SOURCE,MODEL,work)
    body=DynamicHiFTBody(hift).eval()
    fixed_class=load_fixed_oracle_class(SOURCE)
    hift.f0_predictor.double()
    rows=[]
    for n in COUNTS:
        g=2*n
        noise,norm=frame_buffers(hift,g)
        for variant in ('dynamic','source','frozen'):
            if variant=='frozen' and n!=225: continue
            array = (np.load(work/f'flow-N{n}.npz')['source_mel'] if variant=='source'
                     else np.load(work/f'{variant}-mel-N{n}.npy'))
            mel=torch.from_numpy(np.array(array,copy=True)).float().contiguous()
            fixed=fixed_class(hift,g).eval()
            with torch.no_grad():
                f0=hift.f0_predictor(mel.double(),finalize=True).float().contiguous()
                phase=host_phase(f0)
                expected=body(mel,f0,phase,noise,norm).numpy().copy()
                fixed_pcm=fixed(mel,f0,phase).numpy().copy()
                upstream,_=hift.inference(mel,finalize=True)
                upstream=upstream.numpy().copy()
            exact=metrics(fixed_pcm,expected)
            if exact['maxAbsError']!=0: raise RuntimeError(f'source body contract changed: {exact}')
            np.savez(work/f'hift-{variant}-N{n}.npz',mel=mel.numpy(),f0=f0.numpy(),phase=phase.numpy(),
                     noise=noise.numpy(),norm=norm.numpy(),body=expected,upstream=upstream)
            rows.append({'N':n,'variant':variant,'sourceDynamicVsFixed':exact,
                         'sourceBodyVsUpstreamFP64':metrics(upstream,expected)})
            save_json(work/'source-hift-results.json',rows)
            print(f'[DYNAMIC-HOST] FP64 F0/source HiFT {variant} N{n} complete',flush=True)
    save_json(work/'config-receipt.json',config)


def hift_host(work):
    model=ct.models.MLModel(str(HIFT),compute_units=ct.ComputeUnit.CPU_ONLY)
    _,fixed_path=fixed_asset_hift(FIXED)
    fixed=ct.models.MLModel(str(fixed_path),compute_units=ct.ComputeUnit.CPU_ONLY)
    rows=[]
    for n in COUNTS:
        values=dict(np.load(work/f'hift-dynamic-N{n}.npz'))
        feed={k:values[k] for k in ('mel','f0','phase','noise','norm')}
        pcm=model.predict(feed)['pcm']
        np.save(work/f'dynamic-pcm-N{n}.npy',pcm)
        source=dict(np.load(work/f'hift-source-N{n}.npz'))
        row={'N':n,'T':302+2*n,'G':2*n,'expectedSamples':960*n,'pcmShape':list(pcm.shape),
             'finite':bool(np.isfinite(pcm).all()),'f0Dtype':'float64 then float32 output',
             'sameMelCoreMLVsSourceBody':metrics(values['body'],pcm),
             'sameMelCoreMLVsUpstreamFP64':metrics(values['upstream'],pcm),
             'fullDynamicEndpointVsSourceNatural':metrics(source['upstream'],pcm)}
        row['componentHiFTGatePass']=(row['finite'] and pcm.shape==(1,960*n)
            and row['sameMelCoreMLVsSourceBody']['relativeL2']<=.02
            and row['sameMelCoreMLVsUpstreamFP64']['relativeL2']<=.02)
        if n==225:
            frozen=dict(np.load(work/f'hift-frozen-N{n}.npz'))
            frozen_pcm=fixed.predict({k:frozen[k] for k in ('mel','f0','phase')})['pcm']
            identical_pcm=fixed.predict({k:values[k] for k in ('mel','f0','phase')})['pcm']
            row['identicalMelDynamicHiFTVsFrozenHiFT']=metrics(identical_pcm,pcm)
            row['fullDynamicEndpointVsFrozenFixed225']=metrics(frozen_pcm,pcm)
            row['fullFrozenEndpointVsSourceNatural']=metrics(source['upstream'],frozen_pcm)
            np.save(work/'frozen-pcm-N225.npy',frozen_pcm)
        rows.append(row)
        save_json(work/'hift-results.json',rows)
        print(f'[DYNAMIC-HOST] endpoint N{n}: {json.dumps(row)}',flush=True)


def main():
    p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True)
    p.add_argument('--phase',choices=('source_flow','flow_host','source_hift','hift_host'))
    p.add_argument('--family',type=Path)
    p.add_argument('--text-traces',type=Path)
    a=p.parse_args()
    global FLOW,HIFT,COND,COUNTS,TRACES
    if a.family:
        FLOW=a.family/'packages';HIFT=a.family/'hift/hift-dynamic-body-fp32.mlpackage';COND=a.family/'conditions/conditions.mlpackage'
    if a.text_traces:
        TRACES={r['N']:r for r in (json.loads(f.read_text()) for f in sorted(a.text_traces.glob('text-*.json')))}
        if not all(r.get('actualEarlyEOS') and r.get('stopToken')==6562 and len(r['speechTokens'])==r['N'] for r in TRACES.values()): raise RuntimeError('Real EOS/count not proven')
        COUNTS=tuple(sorted(set((186,225))|set(TRACES)))
    if a.phase:
        globals()[a.phase](a.output);return 0
    a.output.mkdir(parents=True,exist_ok=False)
    r={'schemaVersion':1,'status':'RUNNING','sourceCommit':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
       'pinnedUpstream':PIN,'productionPromotion':False,'actualDynamicFlowMel':True,
       'numericalPolicy':'Existing same-mel HiFT relativeL2<=0.02; full endpoint and FP16 Flow errors recorded against source/frozen controls; no new endpoint threshold invented.',
       'packages':{'flow':[{'path':str(FLOW/f'shard-{i:02d}/flow-shard.mlpackage'),'sha256':sha(FLOW/f'shard-{i:02d}/flow-shard.mlpackage')} for i in range(6)],
                   'conditions':{'path':str(COND),'sha256':sha(COND)},'hift':{'path':str(HIFT),'sha256':sha(HIFT)}},
       'realTextTraces':list(TRACES.values())}
    try:
        for phase in ('source_flow','flow_host','source_hift','hift_host'):
            r['phase']=phase;save_json(a.output/'receipt.json',r)
            command=[sys.executable,__file__,'--output',str(a.output),'--phase',phase]
            if a.family:command+=['--family',str(a.family)]
            if a.text_traces:command+=['--text-traces',str(a.text_traces)]
            subprocess.run(command,check=True)
        r['flowTests']=json.loads((a.output/'flow-results.json').read_text())
        r['sourceTests']=json.loads((a.output/'source-hift-results.json').read_text())
        r['tests']=json.loads((a.output/'hift-results.json').read_text())
        r['componentGatesPass']=all(row['componentHiFTGatePass'] for row in r['tests'])
        r['status']='PASS_HOST_DYNAMIC_ACOUSTIC_EXECUTION_COMPONENT_GATES_ENDPOINT_NUMERICS_RECORDED_NOT_PROMOTED' if r['componentGatesPass'] else 'FAIL_HOST_DYNAMIC_ACOUSTIC_HIFT_GATE'
        r['phase']='complete'
    except Exception as e:
        r.update(status='FAIL',error=str(e),traceback=traceback.format_exc())
    save_json(a.output/'receipt.json',r)
    print(json.dumps(r,indent=2),flush=True)
    return 0 if r['status'].startswith('PASS_') else 1

if __name__=='__main__':raise SystemExit(main())
# Purpose: experiment-only natural-length complete acoustic host proof with component and endpoint controls.
# Upstream: pinned CosyVoice3 Flow and HiFT, existing Phase2/3 symbolic packages, frozen fixed225 control.
# Environment: macOS arm64 Python3.11/CoreML CPU_ONLY; isolated subprocesses prevent PyTorch/CoreML runtime interference.
# Generated: 2026-10-04 America/New_York. New file, all lines. No LLM/cap/assets/Candidate change.

# 2026-10-04: accept an explicitly re-exported family and hash-preserved real
# early-EOS token traces; test observed counts alongside original186/225 controls.
