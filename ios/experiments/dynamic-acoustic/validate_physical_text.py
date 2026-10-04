# validate_physical_text.py
# Requirement: verify actual physical early-EOS text receipts, PCM hashes/counts, same-device-mel upstream FP64 HiFT gate, and full source acoustic controls; preserve raw PCM when creating WAV previews.
import argparse,json,subprocess,traceback
from pathlib import Path
import numpy as np
import torch
from scipy.io import wavfile
from probe_symbolic_conditions import ROOT,PIN,SymbolicConditions,sha
from run_shard0_attribution import metrics
from run_phase2_dynamic_flow import load_estimator,load_full_graph,natural_inputs,source_rollout,load_reference_flow_conditioning
from run_phase3_dynamic_hift import load_hift,DynamicHiFTBody,frame_buffers,host_phase
BASE=ROOT/'ios/.work/rebuild/ios-fixed225-reference'

def main():
    p=argparse.ArgumentParser();p.add_argument('--device-work',type=Path,required=True);p.add_argument('--receipt',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    a.output.mkdir(parents=True,exist_ok=False)
    device=json.loads(a.receipt.read_text())
    report={'schemaVersion':1,'status':'RUNNING','sourceCommit':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
        'pinnedUpstream':PIN,'rawDeviceReceiptSha256':sha(a.receipt),'tests':[],'productionPromotion':False,
        'acceptance':'Existing same-mel shipping HiFT FP64 relativeL2<=0.02; full endpoint divergence diagnostic; audible quality/Candidate acceptance separate.'}
    def save():(a.output/'receipt.json').write_text(json.dumps(report,indent=2,sort_keys=True)+'\n')
    save()
    try:
        if device['status']!='PASS_PHYSICAL_REAL_TEXT_NATURAL_PCM_EXECUTION_NOT_PROMOTED' or not device['physicalDevice']:raise RuntimeError('Physical complete real-text proof absent')
        traces=device['realTextTraces']
        if not all(t['actualEarlyEOS'] and t['stopToken']==6562 and len(t['speechTokens'])==t['N'] for t in traces):raise RuntimeError('Actual native early EOS missing')
        torch.set_num_threads(4)
        source=BASE/'source';model=BASE/'model-cache/Fun-CosyVoice3-0.5B-2512';fixture=BASE/'fixture'
        estimator=load_estimator(source,model);full=load_full_graph(source,estimator)
        conditioning=SymbolicConditions(load_reference_flow_conditioning(model/'flow.pt')).eval()
        flow=torch.load(fixture/'flow_input.pt',weights_only=True)['kwargs'];args0=torch.load(fixture/'estimator_00.pt',weights_only=True)['args']
        natural_mels=[]
        for trace in traces:
            current=dict(flow);current['token']=torch.tensor([trace['speechTokens']],dtype=torch.int32)
            case=natural_inputs(trace['N'],conditioning,current,args0)
            natural_mels.append(source_rollout(full,case).detach()[:,:,302:].contiguous())
        hift,config=load_hift(source,model,a.output);body=DynamicHiFTBody(hift).eval();hift.f0_predictor.double()
        report['acousticConfig']=config
        for index,(trace,row,source_mel) in enumerate(zip(traces,device['tests'],natural_mels)):
            n=trace['N'];g=2*n;samples=g*480
            if (row['N'],row['T'],row['G'],row['samples'])!=(n,302+2*n,g,samples):raise RuntimeError('Device natural geometry mismatch')
            pcm_path=a.device_work/row['pcmFileName'];mel_path=a.device_work/f'device-text-{index}-mel.f32'
            pcm=np.fromfile(pcm_path,dtype=np.float32).reshape(1,-1);device_mel=torch.from_numpy(np.fromfile(mel_path,dtype=np.float32).reshape(1,80,g).copy())
            if pcm.shape!=(1,samples) or not np.isfinite(pcm).all():raise RuntimeError('Device PCM size/finite failure')
            with torch.no_grad():
                f0=hift.f0_predictor(device_mel.double(),finalize=True).float().contiguous();phase=host_phase(f0);noise,norm=frame_buffers(hift,g)
                same_body=body(device_mel,f0,phase,noise,norm).numpy()
                upstream,_=hift.inference(device_mel,finalize=True);upstream=upstream.numpy()
                source_pcm,_=hift.inference(source_mel,finalize=True);source_pcm=source_pcm.numpy()
            body_metric=metrics(same_body,pcm);upstream_metric=metrics(upstream,pcm)
            preview=a.output/f'text-{index}-N{n}.wav';wavfile.write(preview,24000,pcm[0])
            check_rate,check_pcm=wavfile.read(preview)
            if check_rate!=24000 or not np.array_equal(check_pcm,pcm[0]):raise RuntimeError('WAV preview modified PCM')
            test={'textIndex':index,'text':trace['text'],'N':n,'T':302+2*n,'G':g,'samples':samples,'seconds':samples/24000,
                  'stopToken':trace['stopToken'],'actualEarlyEOS':True,'pcmSha256':sha(pcm_path),'melSha256':sha(mel_path),
                  'sameDeviceMelPCMVsSourceBody':body_metric,'sameDeviceMelPCMVsUpstreamFP64':upstream_metric,
                  'deviceMelVsSourceNatural':metrics(source_mel.numpy(),device_mel.numpy()),
                  'fullDeviceEndpointVsSourceNatural':metrics(source_pcm,pcm),'wavPath':str(preview),'wavSha256':sha(preview),
                  'sameMelHiFTGatePass':body_metric['finite'] and upstream_metric['finite'] and body_metric['relativeL2']<=.02 and upstream_metric['relativeL2']<=.02}
            report['tests'].append(test);save();print('[PHYSICAL-TEXT] '+json.dumps(test),flush=True)
        report['status']='PASS_PHYSICAL_TEXT_NATURAL_PCM_HIFT_COMPONENT_NOT_PROMOTED' if all(t['sameMelHiFTGatePass'] for t in report['tests']) else 'FAIL_PHYSICAL_TEXT_HIFT_COMPONENT_GATE'
    except Exception as e:report.update(status='FAIL',error=str(e),traceback=traceback.format_exc())
    save();print(json.dumps(report,indent=2),flush=True);return 0 if report['status'].startswith('PASS_') else 1
if __name__=='__main__':raise SystemExit(main())
# Purpose: bind actual physical text/EOS/PCM provenance to original numerical gates and source controls.
# Upstream: pinned official Flow/HiFT and experiment physical receipts, no CoreML execution in this validator.
# Environment: macOS arm64 Python3.11/torch2.7/SciPy1.13.1; WAV stores identical Float32 PCM.
# Generated: 2026-10-04 America/New_York. New file, all lines; no cap/public assets/Candidate changes.
