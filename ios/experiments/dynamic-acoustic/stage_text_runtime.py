# stage_text_runtime.py
# Requirement: stage immutable LLM/tokenizer/embedding controls for physical real-text proof; bind every copied payload without modifying release assets.
import argparse,json,shutil,subprocess
from pathlib import Path
from probe_symbolic_conditions import ROOT,sha

def main():
    p=argparse.ArgumentParser();p.add_argument('--library',type=Path,required=True);a=p.parse_args()
    source=ROOT/'ios/.work/production-clean-room/fetched-runtime'
    dest=Path(__file__).parent/'DeviceProbe/GeneratedAssets/text-runtime';dest.mkdir(parents=True,exist_ok=False)
    manifest=json.loads((source/'cosyvoice3_fixed225.json').read_text())
    identity={'sourceCommit':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
       'libraryIdentity':json.loads((a.library/'identity.json').read_text()),'payloads':{},'productionPromotion':False,
       'flowReferenceProvenance':'Pinned enrollment fixture Q151/P302; native LLM default assistant prompt, no reference transcript supplied to frontend.'}
    for relative in ('cosyvoice3_fixed225.json',manifest['tokenizerFolder'],'embeddings',manifest['llmPrefill'],manifest['llmDecode']):
        target=dest/relative;target.parent.mkdir(parents=True,exist_ok=True);original=source/relative
        if original.is_dir():shutil.copytree(original,target)
        else:shutil.copy2(original,target)
        before,after=sha(original),sha(target)
        if before!=after:raise RuntimeError(f'Copy hash mismatch: {relative}')
        identity['payloads'][relative]=before
        print(f'[TEXT-STAGING] {relative} sha256={before}',flush=True)
    (dest/'identity.json').write_text(json.dumps(identity,indent=2)+'\n')
if __name__=='__main__':main()
# Purpose: isolated physical text inputs/control model provenance. Upstream: frozen release assets read-only.
# Environment: local macOS Python3.11. Generated: 2026-10-04 America/New_York.
# New file, all lines; copied large artifacts ignored under GeneratedAssets, source release unchanged.
