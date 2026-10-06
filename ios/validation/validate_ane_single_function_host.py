# validate_ane_single_function_host.py
# Requirement: same-input host prediction parity for extracted single-function vs frozen multifunction n257_384, at exact N260.
from __future__ import annotations
import argparse
import gc
import json
import time
from pathlib import Path
import coremltools as ct
import numpy as np

def main():
 p=argparse.ArgumentParser();p.add_argument('--asset-root',type=Path,required=True);p.add_argument('--experimental-root',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
 exp=json.loads((a.experimental_root/'export-receipt.json').read_text());rng=np.random.default_rng(42)
 receipt=dict(schemaVersion=1,status='RUNNING',scope='HOST_COMPONENT_SYNTHETIC_INPUT_ONLY_NOT_PHYSICAL_OR_ENDPOINT_PARITY',N=260,models={})
 for role,row in exp['models'].items():
  inputs={};spec=ct.models.MLModel(str(a.experimental_root/(role+'.mlpackage')),skip_model_load=True).get_spec()
  for f in spec.description.input:
   arr=f.type.multiArrayType;shapes=list(arr.enumeratedShapes.shapes);shape=list(shapes[3].shape) if shapes else list(arr.shape)
   dtype=np.int32 if arr.dataType==131104 else np.float32
   if dtype==np.int32: val=rng.integers(0,1000,size=shape,dtype=np.int32)
   elif f.name in ['mask']:val=np.ones(shape,np.float32)
   elif f.name=='mel':val=rng.normal(-3,0.1,size=shape).astype(np.float32)
   else:val=rng.normal(0,0.01,size=shape).astype(np.float32)
   inputs[f.name]=val
  outputs=[];times=[];errors=[]
  for path,fn in [(a.asset_root/row['source'],'n257_384'),(a.experimental_root/(role+'.mlpackage'),None)]:
   start=time.monotonic()
   try:
    model=ct.models.MLModel(str(path),function_name=fn,compute_units=ct.ComputeUnit.CPU_ONLY)
    outputs.append(model.predict(inputs));del model;gc.collect();times.append(time.monotonic()-start)
   except Exception as e:errors.append(str(e));break
  result=dict(inputs={k:dict(shape=list(v.shape),dtype=str(v.dtype)) for k,v in inputs.items()},elapsedSeconds=times)
  if errors:result.update(status='FAIL',errors=errors)
  else:
   metrics={k:dict(maxAbs=float(np.max(np.abs(outputs[0][k].astype(np.float64)-outputs[1][k]))),finite=bool(np.isfinite(outputs[1][k]).all()),shape=list(outputs[1][k].shape)) for k in outputs[0]}
   result.update(status='PASS' if all(v['maxAbs']==0 and v['finite'] for v in metrics.values()) else 'FAIL',outputs=metrics)
  receipt['models'][role]=result;a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(receipt,indent=2)+'\n');print('[ANE-SINGLE-HOST-PARITY]',role,result,flush=True)
 receipt['status']='PASS_HOST_PACKAGING_PARITY' if all(v['status']=='PASS' for v in receipt['models'].values()) else 'FAIL_HOST_PACKAGING_PARITY';a.output.write_text(json.dumps(receipt,indent=2)+'\n')
if __name__=='__main__':main()
# Purpose: same graph/weights packaging check at exact N260; upstream frozen n257_384 graph, purpose acoustic inference.
# Environment Python3.11/coremltools9/macOS CPU_ONLY; generated 2026-10-05 America/New_York; new file.
