# prepare_llm_quantization_recipe.py
# Requirement: content-bound isolated Q8 root recipe reusing immutable non-LLM files through device-local hard links.
import argparse,hashlib,json,subprocess
from pathlib import Path

def sha(path):
 h=hashlib.sha256()
 with path.open('rb') as f:
  for b in iter(lambda:f.read(4*1024*1024),b''):h.update(b)
 return h.hexdigest()
def tree(rows):return hashlib.sha256(''.join(f"{r['path']}\0{r['bytes']}\0{r['sha256']}\n" for r in sorted(rows,key=lambda r:r['path'])).encode()).hexdigest()
def main():
 p=argparse.ArgumentParser();p.add_argument('--baseline',type=Path,required=True);p.add_argument('--payload',type=Path,required=True);p.add_argument('--evidence',type=Path,required=True);p.add_argument('--bits',type=int,choices=[8,4],default=8);a=p.parse_args();a.payload.mkdir(parents=True,exist_ok=True);a.evidence.mkdir(parents=True,exist_ok=True)
 tag=f'Q{a.bits}';assert not (a.payload/'cosyvoice3_enumerated.json').exists(),'never overwrite existing profile manifest'
 baseline=[];reuse=[];old=['models/llm-opt-perlayer-prefill.mlpackage/','models/llm-opt-perlayer-decode-maskwrite512.mlpackage/']
 for path in sorted(a.baseline.rglob('*')):
  rel=path.relative_to(a.baseline).as_posix()
  if not path.is_file() or '.family-build' in path.parts or path.name=='enumerated-production-export-receipt.json':continue
  row={'path':rel,'bytes':path.stat().st_size,'sha256':sha(path)};baseline.append(row)
  if rel!='cosyvoice3_enumerated.json' and not any(rel.startswith(x) for x in old):reuse.append(row)
 assert tree(baseline)=='4750dba5e727276d22b71399b702a33597aaaf36d61edf8cc3dd8bd3897e6efa'
 manifest=json.loads((a.baseline/'cosyvoice3_enumerated.json').read_text());manifest['llmPrefill']=f'models/cosyvoice-llm-{tag.lower()}-prefill.mlpackage';manifest['llmDecode']=f'models/cosyvoice-llm-{tag.lower()}-decode.mlpackage';manifest['experimentalLLMVariant']=tag+'_WEIGHT_ONLY_UNPROMOTED';(a.payload/'cosyvoice3_enumerated.json').write_text(json.dumps(manifest,indent=2)+'\n')
 rows=list(reuse)
 for path in sorted(a.payload.rglob('*')):
  if path.is_file() and path.name not in ['enumerated-production-export-receipt.json','quantization-recipe.json']:rows.append({'path':path.relative_to(a.payload).as_posix(),'bytes':path.stat().st_size,'sha256':sha(path)})
 identity=tree(rows);conversion=json.loads((a.evidence/'conversion_receipt.json').read_text());recipe={'schemaVersion':1,'variant':tag+'_WEIGHT_ONLY','parentPayloadTreeSHA256':tree(baseline),'payloadTreeSha256':identity,'payloadBytes':sum(r['bytes'] for r in rows),'manifestSHA256':sha(a.payload/'cosyvoice3_enumerated.json'),'sourceCommit':conversion['sourceCommit'],'reuseFiles':reuse,'candidateFiles':[r for r in rows if r not in reuse],'modelIdentity':conversion['models'],'method':conversion['config'],'hardLinkMeaning':'sameunchangedbytefiles; no symlinkescape orsharedmutablemodelbuffers; neverwritebaselinefiles','productionPromotion':False}
 receipt={'schemaVersion':1,'status':f'EXPERIMENTAL_{tag}_NOT_PRODUCTION','sourceCommit':conversion['sourceCommit'],'payloadTreeSha256':identity,'payloadBytes':recipe['payloadBytes'],'parentAssetExportSourceCommit':'ac31e117938ed50132365973a103cc8425942700','parentPayloadTreeSha256':tree(baseline),'LLMWeightCompression':conversion['config'],'productionPromotion':False};(a.payload/'enumerated-production-export-receipt.json').write_text(json.dumps(receipt,indent=2)+'\n');(a.payload.parent/'quantization-recipe.json').write_text(json.dumps(recipe,indent=2)+'\n');(a.evidence/'asset_recipe.json').write_text(json.dumps(recipe,indent=2)+'\n');print('['+tag+'-RECIPE]',identity,recipe['payloadBytes'],'reusedimmutablefiles',len(reuse),flush=True)
if __name__=='__main__':main()
# Purpose: candidateactual-contentidentity without multiGB hostcopies orproduction overwrite.
# Upstream frozen schema3 asset; Python3/macOS/device-privatehardlinks; generated2026-10-06 America/New_York.
# Q4 update2026-10-06: explicit bits selector affects only isolated model filenames/metadata; rejects existing manifest overwrite, defaultsQ8 unchanged. Git diff line map.
