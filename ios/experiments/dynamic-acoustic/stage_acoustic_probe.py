# stage_acoustic_probe.py
# Requirement: stage hash-pinned host-passing full acoustic family and natural fixtures without touching prior probe or frozen assets.
import argparse,json,shutil,subprocess
from pathlib import Path
import numpy as np
from probe_symbolic_conditions import ROOT,sha

def main():
    p=argparse.ArgumentParser();p.add_argument('--host-work',type=Path,required=True);a=p.parse_args()
    work=a.host_work;r=json.loads((work/'receipt.json').read_text())
    if not r.get('componentGatesPass'):raise RuntimeError('Host component gates not passed')
    dest=Path(__file__).parent/'DeviceProbe/GeneratedAssets/acoustic'
    dest.mkdir(parents=True,exist_ok=False)
    identity={'sourceCommit':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
              'hostReceiptSha256':sha(work/'receipt.json'),'productionPromotion':False,
              'probeSwiftSha256':sha(Path(__file__).parent/'DeviceProbe/DynamicAcousticProbe/DynamicAcousticProbeApp.swift'),
              'models':{},'fixtures':{}}
    packages=r['packages']
    roles=[('conditions',packages['conditions'])]+[(f'flow-{i}',row) for i,row in enumerate(packages['flow'])]+[('hift',packages['hift'])]
    for role,row in roles:
        source=Path(row['path'])
        if sha(source)!=row['sha256']:raise RuntimeError(f'{role} changed')
        shutil.copytree(source,dest/f'{role}.mlpackage');identity['models'][role]=row['sha256']
    shutil.copytree(ROOT/'ios/.work/production-clean-room/fetched-runtime/f0-double',dest/'f0-double')
    identity['f0WeightsSha256']=sha(dest/'f0-double')
    identity['counts']=[row['N'] for row in r['tests']]
    for n in identity['counts']:
        folder=dest/f'N{n}';folder.mkdir()
        flow=dict(np.load(work/f'flow-N{n}.npz'));hift=dict(np.load(work/f'hift-dynamic-N{n}.npz'))
        values={k:flow[f'input_{k}'] for k in ('tokens','prompt_tokens','prompt_feat','speaker')}
        values.update(noise=flow['noise'],norm=hift['norm'])
        values['hift-noise']=hift['noise'];values['expected-mel']=hift['mel']
        values['expected-pcm']=np.load(work/f'dynamic-pcm-N{n}.npy')
        for k,v in values.items():np.asarray(v).tofile(folder/f'{k}.bin')
        identity['fixtures'][str(n)]={f.name:sha(f) for f in folder.glob('*.bin')}
    (dest/'identity.json').write_text(json.dumps(identity,indent=2)+'\n');print(json.dumps(identity,indent=2))
if __name__=='__main__':main()
# Purpose: independent full acoustic physical staging; upstream Phase2/3 host family.
# Environment: local macOS Python3.11. Generated: 2026-10-04 America/New_York.
# New file, all lines; large assets remain ignored, previous staging preserved.

# 2026-10-04: stage observed EOS lengths and original controls from host receipt.
