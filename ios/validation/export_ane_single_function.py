# export_ane_single_function.py
# Requirement: extract exact n257_384 acoustic graphs into independent single-main-function diagnostics; never overwrite baseline.
from __future__ import annotations
import argparse
import copy
import json
import subprocess
from pathlib import Path
import coremltools as ct
from audit_enumerated_ane_graphs import fingerprint

def main():
 p=argparse.ArgumentParser();p.add_argument('--asset-root',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--roles',nargs='+',default=['conditions',*[f'flow{i}' for i in range(6)],'hift']);a=p.parse_args()
 a.output.mkdir(parents=True,exist_ok=True)
 manifest=json.loads((a.asset_root/'cosyvoice3_enumerated.json').read_text())
 paths=dict(conditions=manifest['flowConditions'],hift=manifest['hift'],**{f'flow{i}':f'enumerated-acoustic/flow-shard-{i}.mlpackage' for i in range(6)})
 receipt=dict(schemaVersion=1,sourceCommit=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),function='n257_384',scope='single-function packaging only; selected function operations and weights unchanged',models={},productionPromotion=False)
 for role in a.roles:
  destination=a.output/(role+'.mlpackage')
  if destination.exists():raise RuntimeError('never overwrite diagnostic '+str(destination))
  original=ct.models.MLModel(str(a.asset_root/paths[role]),skip_model_load=True);source=original.get_spec();spec=copy.deepcopy(source)
  selected=next(f for f in source.description.functions if f.name=='n257_384')
  spec.description.input.extend(selected.input);spec.description.output.extend(selected.output);spec.description.state.extend(selected.state)
  spec.description.ClearField('functions');spec.description.ClearField('defaultFunctionName')
  function=copy.deepcopy(source.mlProgram.functions['n257_384']);spec.mlProgram.ClearField('functions');spec.mlProgram.functions['main'].CopyFrom(function)
  spec.specificationVersion=8
  assert spec.mlProgram.functions['main'].SerializeToString(deterministic=True)==source.mlProgram.functions['n257_384'].SerializeToString(deterministic=True)
  ct.models.MLModel(spec,weights_dir=original.weights_dir,skip_model_load=True).save(str(destination))
  before=fingerprint(a.asset_root/paths[role]);after=fingerprint(destination)
  weights=lambda x:sorted((r['bytes'],r['sha256']) for r in x['files'] if '/weights/' in r['path'])
  assert weights(before)==weights(after),'weight bytes must match'
  receipt['models'][role]=dict(source=paths[role],sourceIdentity=before,experimentalIdentity=after,graphIdentical=True,weightsIdentical=True,description=str(spec.description),status='EXPORTED_NOT_DEVICE_VALIDATED')
  (a.output/'export-receipt.json').write_text(json.dumps(receipt,indent=2,sort_keys=True)+'\n')
  print('[ANE-SINGLE-EXPORT]',role,after['bytes'],'graph/weights unchanged',flush=True)
if __name__=='__main__':main()
# Purpose: distinguish multifunction/ANE specialization failure from graph op failure using same n257_384 graph.
# Upstream: frozen schema-3 multifunction acoustic package; upstream purpose deduplicated exact N1...450 inference.
# Environment: Python3.11/coremltools9/macOS; generated 2026-10-05 America/New_York. New file; metadata/function packaging only.
