# assemble_q4_full_prefill_candidate.py
# Requirement: isolate full rescue-A Q4 prefill plus frozen rescue-A decode; preserve accepted hybrid and every reused acoustic/reference byte.
import hashlib,json,os,shutil,subprocess
from pathlib import Path

def sha(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for b in iter(lambda:f.read(4*1024*1024),b''):h.update(b)
 return h.hexdigest()
def tree(root,exclude=False):
 rows=[{'path':p.relative_to(root).as_posix(),'bytes':p.stat().st_size,'sha256':sha(p)} for p in sorted(root.rglob('*')) if p.is_file() and not(exclude and (p.name=='enumerated-production-export-receipt.json' or '.family-build' in p.parts))]
 return {'treeSha256':hashlib.sha256(''.join(f"{r['path']}\0{r['bytes']}\0{r['sha256']}\n" for r in rows).encode()).hexdigest(),'bytes':sum(r['bytes'] for r in rows),'files':rows}
def main():
 parent=Path('ios/.work/q4-rescue-20261006/Hybrid');dest=Path('ios/.work/q4-prefill-length-20261006/Full');assert not dest.exists()
 source=Path('ios/.work/q4-rescue-20261006/A/models/cosyvoice-llm-q4-prefill.mlpackage')
 before=tree(parent/'Runtime',True);assert before['treeSha256']=='3b57dab13798145f0f4d258c2d0e3903340594ebea85a3775f643e664b83dfd9'
 pref=tree(source);assert pref['treeSha256']=='905f29f5ffa83161cf91d4d93db6fd28423f246b0e43acdbbe1ff646151eaee4'
 shutil.copytree(parent,dest,copy_function=os.link)
 root=dest/'Runtime';shutil.rmtree(root/'models/cosyvoice-llm-q8-prefill.mlpackage')
 target=root/'models/cosyvoice-llm-q4-full-prefill.mlpackage';shutil.copytree(source,target,copy_function=os.link)
 manifest=root/'cosyvoice3_enumerated.json';m=json.loads(manifest.read_text());m['llmPrefill']='models/cosyvoice-llm-q4-full-prefill.mlpackage';manifest.unlink();manifest.write_text(json.dumps(m,indent=2,sort_keys=True)+'\n')
 payload=tree(root,True);export=root/'enumerated-production-export-receipt.json';export.unlink();export.write_text(json.dumps({'schemaVersion':1,'sourceCommit':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),'status':'EXPERIMENTAL_FULL_Q4_PREFILL_NOT_VALIDATED','payloadTreeSha256':payload['treeSha256'],'payloadBytes':payload['bytes'],'productionPromotion':False},indent=2)+'\n')
 recipe=dest/'quantization-recipe.json';rx=json.loads(recipe.read_text());rx.update(variant='q4_full_prefill_a',payloadTreeSha256=payload['treeSha256'],payloadBytes=payload['bytes'],manifestSHA256=sha(manifest),prefillPackageSHA256=pref['treeSha256'],decodeUnchanged=True);recipe.unlink();recipe.write_text(json.dumps(rx,indent=2)+'\n')
 assert tree(parent/'Runtime',True)==before
 dec=tree(root/'models/cosyvoice-llm-q4-rescue-a-decode.mlpackage');assert dec['treeSha256']=='4685dcbfe07df1e06ece018f9e0cd5184405ea29440c2d3ed85e4116bcb9ca46'
 old={r['path']:r for r in before['files']};changed=[r['path'] for r in payload['files'] if old.get(r['path'])!=r];removed=sorted(set(old)-{r['path'] for r in payload['files']})
 receipt={'candidate':'q4_full_prefill_a','parentHybridIdentity':before,'manifestSHA256':sha(manifest),'payloadIdentity':payload,'prefillIdentity':pref,'decodeIdentity':dec,'changedPaths':changed,'removedPaths':removed,'root':str(root.resolve()),'sourceCommit':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),'productionProfileChanged':False,'decodeUnchanged':True,'parentUnchanged':True}
 out=Path('ios/validation/evidence/q4_prefill_length_memory_20261006/q4_full_prefill');out.mkdir(exist_ok=True);(out/'asset_collection.json').write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps({k:receipt[k] for k in ['manifestSHA256','root','changedPaths','removedPaths']},indent=2));print('payload',payload['treeSha256'])
if __name__=='__main__':main()
# Purpose: readonly same-volume hardlinks, independent replaced manifest/prefill and receipt, exact frozen decode/Flow/reference.
# Upstream accepted Q8prefill/Q4decode Hybrid asset collection. macOS/CoreML iPhone diagnostics,2026-10-06 America/New_York.
