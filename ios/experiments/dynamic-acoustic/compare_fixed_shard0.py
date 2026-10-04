# compare_fixed_shard0.py
# Requirement: compare identical N225 tensors between one serialized symbolic package and untouched accepted fixed225 shard0, recording provenance and numerical regression.
import argparse,json
from pathlib import Path
import coremltools as ct
import numpy as np
from probe_symbolic_conditions import metrics,sha

def main():
 p=argparse.ArgumentParser();p.add_argument('--dynamic',type=Path,required=True);p.add_argument('--fixed',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
 folder=a.dynamic/'N225';shapes={'x':(2,80,752),'mask':(2,1,752),'mu':(2,80,752),'t':(2,),'spks':(2,80),'cond':(2,80,752)}
 feed={k:np.fromfile(folder/(k+'.bin'),np.float32).reshape(s) for k,s in shapes.items()}
 base=ct.models.MLModel(str(a.fixed),compute_units=ct.ComputeUnit.CPU_ONLY).predict(feed)
 package=a.dynamic/'shard0.mlpackage'
 dyn=ct.models.MLModel(str(package),compute_units=ct.ComputeUnit.CPU_ONLY).predict(feed)
 outputs={k:{'dynamicVsFixed':metrics(base[k],dyn[k]),'fixedVsOfficial':metrics(np.fromfile(folder/('expected-'+k+'.bin'),np.float32).reshape(base[k].shape),base[k])} for k in ('h','te')}
 receipt={'schemaVersion':1,'N':225,'T':752,'baselinePackageSha256':sha(a.fixed),'dynamicPackageSha256':sha(package),'outputs':outputs,'status':'PASS_BIT_EXACT' if all(v['dynamicVsFixed']['maxAbsError']==0 for v in outputs.values()) else 'FAIL_BIT_EXACT_REGRESSION_CONTROL'}
 a.output.write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps(receipt,indent=2))
 return 0 if receipt['status'].startswith('PASS') else 1
if __name__=='__main__':raise SystemExit(main())
# Purpose: identical-input numerical regression control, preserving fixed assets and recording rather than relaxing thresholds.
# Upstream: accepted fixed225 FirstShard and symbolic FirstShard at pinned8789402.
# Environment: local macOS torch2.7/coremltools9. Generated2026-10-03 America/New_York. New file, all lines.
