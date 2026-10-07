# validate_equivalent_flow_partitions.py
# Requirement: frozen six-shard vs 3/2/1 complete velocity prediction parity, same frozen conditioning/noise at exact multi-bucket shapes.
from pathlib import Path
import argparse,gc,json,time,traceback
import coremltools as ct
import numpy as np

def main():
 p=argparse.ArgumentParser();p.add_argument('--asset-root',type=Path,required=True);p.add_argument('--partitions',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--lengths',nargs='+',type=int,default=[1,260,450]);p.add_argument('--counts',nargs='+',type=int,choices=[1,2,3,6],default=[6,3,2,1]);a=p.parse_args();assert 6 in a.counts and a.counts[0]==6,'six-shard reference must run first'
 manifest=json.loads((a.asset_root/'cosyvoice3_enumerated.json').read_text());contract=manifest['enumeratedAcoustic'];rows=[]
 receipt=dict(schemaVersion=1,status='RUNNING',algorithmUnchanged='export structural gate plus numerical controls; physical gate pending',computeUnits='CPU_ONLY',scope='HOST_COMPLETE_VELOCITY_CONTROL_NO_SAMPLER_OR_ENDPOINT_AUDIO',tolerance=dict(atol=0.0003,rtol=0.0003),cases=rows)
 prompt=np.fromfile(a.asset_root/contract['defaultPromptTokens'],dtype=np.int32).reshape(1,151)
 feat=np.fromfile(a.asset_root/contract['defaultPromptFeat'],dtype=np.float32).reshape(1,302,80)
 speaker=np.fromfile(a.asset_root/contract['defaultSpeaker'],dtype=np.float32).reshape(1,192)
 noise=np.fromfile(a.asset_root/contract['flowNoiseMaximum'],dtype=np.float32).reshape(1,80,1202)
 for n in a.lengths:
  fn=next(f['functionName'] for f in contract['families'] if f['speechTokenMinimum']<=n<=f['speechTokenMaximum']);t=302+2*n
  condModel=ct.models.MLModel(str(a.asset_root/manifest['flowConditions']),function_name=fn,compute_units=ct.ComputeUnit.CPU_ONLY)
  conditioning=condModel.predict(dict(tokens=np.resize(prompt,(1,n)).astype(np.int32),prompt_tokens=prompt,prompt_feat=feat,speaker=speaker));del condModel;gc.collect()
  x=np.ascontiguousarray(np.concatenate([noise[:,:,:t],noise[:,:,:t]],axis=0));mask=np.ones((2,1,t),np.float32)
  feeds=dict(x=x,mask=mask,mu=conditioning['mu'],cond=conditioning['cond'],spks=conditioning['spks'],t=np.array([0.25,0.25],np.float32))
  reference=None
  for count in a.counts:
   row=dict(N=n,T=t,function=fn,partition=count,status='RUNNING')
   try:
    paths=[a.asset_root/f'enumerated-acoustic/flow-shard-{i}.mlpackage' for i in range(6)] if count==6 else [a.partitions/f'p{count}/group-{i}.mlpackage' for i in range(count)]
    feed=feeds.copy();start=time.monotonic()
    for i,path in enumerate(paths):
     model=ct.models.MLModel(str(path),function_name=fn,compute_units=ct.ComputeUnit.CPU_ONLY);value=model.predict(feed);del model;gc.collect()
     if 'velocity' in value:velocity=value['velocity']
     elif 'te' in value:feed=dict(h=value['h'],te=value['te'],mask=mask)
     else:feed['h']=value['h_out']
    if count==6:reference=velocity.copy()
    delta=velocity.astype(np.float64)-reference
    row.update(status='PASS' if np.allclose(velocity,reference,atol=3e-4,rtol=3e-4) and np.isfinite(velocity).all() else 'FAIL_NUMERICAL',maxAbs=float(np.max(np.abs(delta))),relativeL2=float(np.linalg.norm(delta)/max(np.linalg.norm(reference),1e-30)),bitIdentical=bool(np.array_equal(velocity,reference)),shape=list(velocity.shape),elapsedSeconds=time.monotonic()-start)
   except Exception as e:row.update(status='FAIL',error=str(e),traceback=traceback.format_exc())
   rows.append(row);a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(receipt,indent=2)+'\n');print('[FLOW-PARTITION-HOST]',row,flush=True)
 receipt['status']='PASS_HOST_VELOCITY_PARITY' if all(r['status']=='PASS' for r in rows) else 'FAIL_HOST_VELOCITY_PARITY';a.output.write_text(json.dumps(receipt,indent=2)+'\n')
if __name__=='__main__':main()
# Purpose: independent numerical comparison of identical mathematical graphs after lossless repack.
# Upstream frozen schema-3 Conditions/Flow; environment coremltools9/Python3.11/macOS CPU_ONLY. Generated2026-10-05 America/New_York; new file.

# Rebuild recovery: --counts 6 2 validates only requested P2 against unchanged six-shard baseline; source order guard and all tolerances unchanged.
# Purpose: bounded relevant host validation; upstream existing complete velocity parity validator.
# Environment: Python3.11/coremltools9/macOS; generated2026-10-06 America/New_York; changed argument/control list only.
