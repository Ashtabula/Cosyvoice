# stage_device_probe.py
# Requirement: stage one exact experimental asset family and natural-length oracle fixtures, bind hashes and symbolic source receipts, never touch frozen Candidate assets.
import argparse,json,shutil,subprocess
from pathlib import Path
from probe_symbolic_conditions import ROOT,sha

def main():
    p=argparse.ArgumentParser();p.add_argument('--conditions',type=Path,required=True);p.add_argument('--shard0',type=Path,required=True);a=p.parse_args()
    dest=Path(__file__).parent/'DeviceProbe/GeneratedAssets'
    dest.mkdir(parents=True,exist_ok=False)
    identity={'profile':'experimental-symbolic-natural-N186-225','sourceCommit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),'modelRevision':'29e01c4e8d000f4bcd70751be16fa94bf3d85a18','scope':'conditioning and shard0 only; synthetic fixture prefixes, no full synthesis','models':{}}
    for role,folder in [('conditions',a.conditions),('shard0',a.shard0)]:
        r=json.loads((folder/'receipt.json').read_text())
        if not r.get('symbolicDimensionRetained') or r.get('conversion')!='PASS':raise RuntimeError(f'{role} symbolic source conversion not proven')
        package=folder/(role+'.mlpackage')
        digest=sha(package)
        if digest!=r['packageSha256']:raise RuntimeError('package changed')
        shutil.copytree(package,dest/package.name)
        for n in [186,225]:shutil.copytree(folder/f'N{n}',dest/role/f'N{n}')
        identity['models'][role]={'packageSha256':digest,'sourceReceiptSha256':sha(folder/'receipt.json'),'flowPtSha256':r['flowPtSha256'],'symbolicDimensionRetained':True,'fixtures':{str(f.relative_to(folder)):sha(f) for n in [186,225] for f in sorted((folder/f'N{n}').glob('*.bin'))}}
    (dest/'identity.json').write_text(json.dumps(identity,indent=2)+'\n')
    print(json.dumps(identity,indent=2))
if __name__=='__main__':main()
# Purpose: reproducible independent device staging with exact model/fixture receipts.
# Upstream: probe_symbolic_conditions.py and probe_symbolic_shard0.py, pinned official checkpoint.
# Environment: local macOS Python3.11. Generated: 2026-10-03 America/New_York. New file, all lines.
