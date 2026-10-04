#!/usr/bin/env python3
# build_dynamic_candidate_assets.py
# Requirement: construct an isolated dynamic-acoustic candidate asset root from the accepted fixed225 runtime plus a validated symbolic family and provenance-bound production stochastic buffers. Fail closed unless the Flow N225 prefix is exact and HiFT excitation is hash-bound to the pinned-upstream buffer receipt.
from __future__ import annotations
import argparse,hashlib,json,shutil
from pathlib import Path
import numpy as np

def sha(path:Path)->str:
    h=hashlib.sha256()
    if path.is_dir():
        for f in sorted(path.rglob('*')):
            if f.is_file():
                h.update(f.relative_to(path).as_posix().encode());h.update(f.read_bytes())
    else:h.update(path.read_bytes())
    return h.hexdigest()

def require(v,msg):
    if not v:raise RuntimeError(msg)

def copy_replace(source:Path,target:Path):
    if target.exists():
        if target.is_dir():shutil.rmtree(target)
        else:target.unlink()
    target.parent.mkdir(parents=True,exist_ok=True)
    if source.is_dir():shutil.copytree(source,target)
    else:shutil.copy2(source,target)

def floats(path:Path,count:int)->np.ndarray:
    a=np.fromfile(path,dtype=np.float32)
    require(a.size==count,f'{path}: expected {count} float32 values, got {a.size}')
    require(np.isfinite(a).all(),f'{path}: non-finite values')
    return a

def main():
    p=argparse.ArgumentParser()
    p.add_argument('--family',type=Path,required=True)
    p.add_argument('--fixed-runtime',type=Path,required=True)
    p.add_argument('--base-conditioning',type=Path)
    p.add_argument('--fixture',type=Path)
    p.add_argument('--flow-noise-max',type=Path,required=True)
    p.add_argument('--hift-excitation-max',type=Path,required=True)
    p.add_argument('--buffer-receipt',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True)
    a=p.parse_args()

    family=json.loads((a.family/'receipt.json').read_text())
    require(family.get('status')=='PASS_FULL_RANGE_SYMBOLIC_FAMILY_EXPORT_NOT_PROMOTED','family export is not PASS')
    nmin,nmax=map(int,family['NBounds'])
    require(1<=nmin<=nmax<=479,f'unsupported family bounds {nmin}...{nmax}')
    require(family['TBounds']==[302+2*nmin,302+2*nmax],'family T bounds mismatch')
    require(family['GBounds']==[2*nmin,2*nmax],'family G bounds mismatch')

    fixed_manifest_path=a.fixed_runtime/'cosyvoice3_fixed225.json'
    fixed=json.loads(fixed_manifest_path.read_text())
    require(fixed.get('profile')=='ios18-fixed225','fixed runtime profile mismatch')
    require(not a.output.exists(),'output must not already exist')
    shutil.copytree(a.fixed_runtime,a.output)

    model_root=a.output/'dynamic-acoustic'
    copies=[
        (a.family/'conditions/conditions.mlpackage',model_root/'conditions.mlpackage'),
        *[(a.family/f'packages/shard-{i:02d}/flow-shard.mlpackage',model_root/f'flow-{i}.mlpackage') for i in range(6)],
        (a.family/'hift/hift-dynamic-body-fp32.mlpackage',model_root/'hift.mlpackage'),
    ]
    for source,target in copies:
        require(source.exists(),f'missing family asset {source}');copy_replace(source,target)

    if a.base_conditioning:
        base_paths={
            'default-prompt-tokens.bin':a.base_conditioning/'prompt_tokens.bin',
            'default-prompt-feat.bin':a.base_conditioning/'prompt_feat.bin',
            'default-speaker.bin':a.base_conditioning/'speaker.bin',
        }
        for name,source in base_paths.items():
            require(source.is_file(),f'missing base conditioning {source}')
            copy_replace(source,model_root/name)
    else:
        require(a.fixture is not None,'provide --base-conditioning or --fixture')
        import torch
        fixture=torch.load(a.fixture/'flow_input.pt',weights_only=True)['kwargs']
        values={
            'default-prompt-tokens.bin':fixture['prompt_token'].int().cpu().numpy().astype(np.int32,copy=False),
            'default-prompt-feat.bin':fixture['prompt_feat'].float().cpu().numpy().astype(np.float32,copy=False),
            'default-speaker.bin':fixture['embedding'].float().cpu().numpy().astype(np.float32,copy=False),
        }
        expected={
            'default-prompt-tokens.bin':(1,151),
            'default-prompt-feat.bin':(1,302,80),
            'default-speaker.bin':(1,192),
        }
        for name,value in values.items():
            require(tuple(value.shape)==expected[name],f'{name} shape mismatch {value.shape}')
            value.tofile(model_root/name)

    max_t=302+2*nmax
    max_samples=960*nmax
    flow_max=floats(a.flow_noise_max,80*max_t).reshape(80,max_t)
    fixed_noise_path=a.fixed_runtime/fixed['flowNoise']
    fixed_noise=floats(fixed_noise_path,80*752).reshape(80,752)
    require(np.array_equal(flow_max[:,:752],fixed_noise),'flowNoiseMaximum N225/T752 prefix is not exact fixed225 noise')
    copy_replace(a.flow_noise_max,model_root/'flow-noise-max.f32')

    buffer_receipt=json.loads(a.buffer_receipt.read_text())
    require(buffer_receipt.get('status')=='PASS_CANDIDATE_STOCHASTIC_BUFFERS_GENERATED_NOT_PROMOTED','buffer receipt is not PASS candidate provenance')
    require(int(buffer_receipt.get('nmax',0))==nmax,'buffer receipt nmax mismatch')
    require(buffer_receipt.get('flowPrefixT752Exact') is True,'buffer receipt has no exact fixed225 Flow prefix proof')
    require(str(buffer_receipt.get('hiftExcitationPolicy','')).startswith('pinned upstream HiFT'),'HiFT excitation is not bound to pinned upstream source policy')
    excitation_max=floats(a.hift_excitation_max,max_samples*9).reshape(max_samples,9)
    hift_prefix=a.hift_excitation_max.parent/'hift-excitation-n225-prefix.f32'
    excitation225=floats(hift_prefix,216000*9).reshape(216000,9)
    require(np.array_equal(excitation_max[:216000],excitation225),'HiFT candidate prefix file does not match max buffer')
    require(sha(a.hift_excitation_max)==buffer_receipt.get('hiftExcitationMaximumSha256'),'HiFT max buffer hash disagrees with provenance receipt')
    require(sha(hift_prefix)==buffer_receipt.get('hiftN225PrefixSha256'),'HiFT N225 prefix hash disagrees with provenance receipt')
    copy_replace(a.hift_excitation_max,model_root/'hift-excitation-max.f32')

    manifest=dict(fixed)
    manifest['schemaVersion']=2
    manifest['profile']=f'ios18-dynamic-n{nmin}-n{nmax}-candidate'
    manifest['flowConditions']='dynamic-acoustic/conditions.mlpackage'
    manifest['flowShards']=[f'dynamic-acoustic/flow-{i}.mlpackage' for i in range(6)]
    manifest['hift']='dynamic-acoustic/hift.mlpackage'
    manifest['dynamicAcoustic']={
        'status':'CANDIDATE',
        'speechTokenMinimum':nmin,
        'speechTokenMaximum':nmax,
        'promptFrameCount':302,
        'defaultPromptTokens':'dynamic-acoustic/default-prompt-tokens.bin',
        'defaultPromptFeat':'dynamic-acoustic/default-prompt-feat.bin',
        'defaultSpeaker':'dynamic-acoustic/default-speaker.bin',
        'flowNoiseMaximum':'dynamic-acoustic/flow-noise-max.f32',
        'hiftExcitationMaximum':'dynamic-acoustic/hift-excitation-max.f32',
    }
    if isinstance(manifest.get('referenceEnrollment'),dict):
        manifest['referenceEnrollment']=dict(manifest['referenceEnrollment'])
        manifest['referenceEnrollment']['flowConditionsDynamic']='dynamic-acoustic/conditions.mlpackage'

    dynamic_manifest=a.output/'cosyvoice3_dynamic.json'
    dynamic_manifest.write_text(json.dumps(manifest,indent=2,sort_keys=True)+'\n')

    receipt={
        'schemaVersion':1,'status':'PASS_DYNAMIC_CANDIDATE_ASSET_ROOT_BUILT_NOT_PROMOTED',
        'profile':manifest['profile'],'NBounds':[nmin,nmax],'TBounds':[302+2*nmin,max_t],
        'GBounds':[2*nmin,2*nmax],'PCMSampleBounds':[960*nmin,max_samples],
        'generationContract':'per request maxN=min(targetTextTokens*20,512-logicalPrefixLength)',
        'fixedManifestSha256':sha(fixed_manifest_path),'dynamicManifestSha256':sha(dynamic_manifest),
        'flowNoiseMaximumSha256':sha(model_root/'flow-noise-max.f32'),
        'flowNoiseN225PrefixExact':True,
        'hiftExcitationMaximumSha256':sha(model_root/'hift-excitation-max.f32'),
        'hiftExcitationSourcePolicy':buffer_receipt['hiftExcitationPolicy'],
        'hiftExcitationN225PrefixSha256':buffer_receipt['hiftN225PrefixSha256'],
        'hiftExcitationHistoricalExactClaim':False,
        'familyReceiptSha256':sha(a.family/'receipt.json'),
        'productionPromotion':False,
    }
    (a.output/'dynamic-candidate-receipt.json').write_text(json.dumps(receipt,indent=2,sort_keys=True)+'\n')
    print(json.dumps(receipt,indent=2,sort_keys=True))

if __name__=='__main__':main()

# Code purpose: build a dual-oracle candidate root where cosyvoice3_dynamic.json activates the new runtime while the copied fixed225 assets remain available for regression.
# Upstream source: accepted fixed225 runtime, PASS symbolic family export, exact default conditioning tensors, and explicitly supplied max Flow/HiFT stochastic buffers.
# Runtime environment: macOS/Linux Python3 with NumPy; no Core ML execution.
# Generated time: 2026-10-04 America/New_York.
# Changes: exact fixed225 Flow prefix gate; pinned-upstream HiFT max/prefix hash binding without circular historical-exact claims; dynamic manifest schema2; generic custom/default conditioning; no zero-noise production fallback and no release promotion.

# 2026-10-04: --fixture can now materialize exact default prompt/reference tensors directly from the pinned flow fixture when staged probe assets are unavailable.
