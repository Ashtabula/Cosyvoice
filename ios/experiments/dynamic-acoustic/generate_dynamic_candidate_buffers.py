#!/usr/bin/env python3
# generate_dynamic_candidate_buffers.py
# Requirement: generate candidate maximum Flow-noise and HiFT-excitation buffers for the dynamic runtime while preserving the accepted fixed225 Flow prefix exactly. HiFT excitation must come from the pinned upstream HiFT source buffer; no zero/noise placeholder is permitted.
from __future__ import annotations
import argparse,json,shutil
from pathlib import Path
import numpy as np
import torch
from run_phase3_dynamic_hift import load_hift,frame_buffers

def require(v,msg):
    if not v:raise RuntimeError(msg)

def main():
    p=argparse.ArgumentParser()
    p.add_argument('--fixed-runtime',type=Path,required=True)
    p.add_argument('--source-root',type=Path,required=True)
    p.add_argument('--model-dir',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--nmax',type=int,default=479)
    p.add_argument('--flow-extension-seed',type=int,default=1986)
    a=p.parse_args()
    require(225<=a.nmax<=479,'nmax must be 225...479')
    require(not a.output.exists(),'output already exists')
    a.output.mkdir(parents=True)

    manifest=json.loads((a.fixed_runtime/'cosyvoice3_fixed225.json').read_text())
    require(manifest.get('profile')=='ios18-fixed225','fixed profile mismatch')
    fixed=np.fromfile(a.fixed_runtime/manifest['flowNoise'],dtype=np.float32)
    require(fixed.size==80*752 and np.isfinite(fixed).all(),'fixed flow noise invalid')
    fixed=fixed.reshape(80,752)

    max_t=302+2*a.nmax
    flow=np.empty((80,max_t),dtype=np.float32)
    flow[:,:752]=fixed
    generator=torch.Generator(device='cpu');generator.manual_seed(a.flow_extension_seed)
    extension=torch.randn((80,max_t-752),generator=generator,dtype=torch.float32).numpy()
    flow[:,752:]=extension
    require(np.array_equal(flow[:,:752],fixed),'fixed flow prefix changed')
    flow_path=a.output/'flow-noise-max.f32';flow.tofile(flow_path)

    work=a.output/'hift-load';work.mkdir()
    hift,_=load_hift(a.source_root,a.model_dir,work)
    excitation,norm=frame_buffers(hift,2*a.nmax)
    expected_samples=960*a.nmax
    require(tuple(excitation.shape)==(1,expected_samples,9),f'HiFT excitation shape mismatch {tuple(excitation.shape)}')
    require(bool(torch.isfinite(excitation).all()),'HiFT excitation non-finite')
    excitation_np=excitation.detach().cpu().numpy().astype(np.float32,copy=False)
    excitation_path=a.output/'hift-excitation-max.f32';excitation_np.tofile(excitation_path)
    prefix_path=a.output/'hift-excitation-n225-reference.f32';excitation_np[:,:216000,:].tofile(prefix_path)

    receipt={
        'schemaVersion':1,'status':'PASS_CANDIDATE_STOCHASTIC_BUFFERS_GENERATED_NOT_PROMOTED',
        'nmax':a.nmax,'maxFlowFrames':max_t,'maxMelFrames':2*a.nmax,'maxPCMSamples':expected_samples,
        'flowPrefixT752Exact':bool(np.array_equal(flow[:,:752],fixed)),
        'flowExtensionPolicy':f'accepted fixed225 prefix + torch.randn CPU continuation seed={a.flow_extension_seed}',
        'flowExtensionSemanticClaim':'Gaussian candidate continuation only; N>225 audible/parity quality requires device validation',
        'hiftExcitationPolicy':'pinned upstream HiFT m_source.l_sin_gen.sine_waves prefix through requested maximum samples',
        'hiftN225ReferenceSamples':216000,'productionPromotion':False,
    }
    (a.output/'receipt.json').write_text(json.dumps(receipt,indent=2,sort_keys=True)+'\n')
    shutil.rmtree(work,ignore_errors=True)
    print(json.dumps(receipt,indent=2,sort_keys=True))

if __name__=='__main__':main()

# Code purpose: produce the two maximum stochastic backing buffers required by CosyVoice3DynamicAcousticRuntime without altering accepted N225 Flow noise or substituting zero HiFT excitation.
# Upstream source: accepted fixed225 flowNoise and pinned upstream HiFT source implementation/checkpoint.
# Runtime environment: macOS arm64 dynamic Python3.11/torch2.7 environment used by the existing dynamic-acoustic experiments.
# Generated time: 2026-10-04 America/New_York.
# Changes: exact fixed225 Flow prefix preservation; explicit Gaussian continuation policy above T752; upstream HiFT excitation extraction to Nmax; no promotion claim.
