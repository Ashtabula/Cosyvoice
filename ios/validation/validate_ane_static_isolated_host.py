# validate_ane_static_isolated_host.py
# Requirement: independent-process exact-input CPU parity to exclude CoreML cross-model buffer/cache interactions; preserve prior failing receipts.
from pathlib import Path
import argparse,json,subprocess,sys,hashlib
import numpy as np
import coremltools as ct

def main():
    p=argparse.ArgumentParser();p.add_argument('--source',type=Path);p.add_argument('--candidate',type=Path);p.add_argument('--output',type=Path)
    p.add_argument('--roles',nargs='+');p.add_argument('--child',action='store_true');p.add_argument('--package');p.add_argument('--function');p.add_argument('--input',type=Path);p.add_argument('--prediction',type=Path)
    a=p.parse_args()
    if a.child:
        model=ct.models.MLModel(a.package,function_name=a.function,compute_units=ct.ComputeUnit.CPU_ONLY)
        with np.load(a.input) as fixture:outputs=model.predict({k:fixture[k] for k in fixture.files})
        np.savez(a.prediction,**{k:np.array(v,copy=True) for k,v in outputs.items()})
        return
    root=Path('/private/tmp/cosy-static-isolated-host');root.mkdir(exist_ok=True)
    export=json.loads((a.candidate/'export-receipt.json').read_text());rng=np.random.default_rng(42)
    receipt=dict(schemaVersion=1,scope='independent macOS CPU processes; synthetic component inputs, not physical or endpoint parity',N=260,models={})
    for role,identity in export['models'].items():
        if a.roles and role not in a.roles:continue
        spec=ct.models.MLModel(str(a.candidate/(role+'.mlpackage')),skip_model_load=True).get_spec();inputs={}
        for feature in spec.description.input:
            shape=list(feature.type.multiArrayType.shape)
            if feature.type.multiArrayType.dataType==131104:value=rng.integers(0,1000,size=shape,dtype=np.int32)
            elif feature.name=='mask':value=np.ones(shape,np.float32)
            elif feature.name=='mel':value=rng.normal(-3,.1,size=shape).astype(np.float32)
            else:value=rng.normal(0,.01,size=shape).astype(np.float32)
            inputs[feature.name]=value
        fixture=root/(role+'-inputs.npz');np.savez(fixture,**inputs)
        runs=[];values=[]
        for label,package,function in [('control',a.source/identity['source'],'n257_384'),('candidate',a.candidate/(role+'.mlpackage'),None)]:
            output=root/(role+'-'+label+'.npz')
            if output.exists():output.unlink()
            command=[sys.executable,__file__,'--child','--package',str(package),'--input',str(fixture),'--prediction',str(output)]
            if function:command+=['--function',function]
            result=subprocess.run(command,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
            print('[ISOLATED-HOST]',role,label,result.returncode,result.stdout,flush=True)
            runs.append(dict(variant=label,returnCode=result.returncode,console=result.stdout,outputsSHA256=hashlib.sha256(output.read_bytes()).hexdigest() if output.exists() else None))
            if output.exists():
                with np.load(output) as data:values.append({k:data[k].copy() for k in data.files})
        metrics={}
        if len(values)==2:
            for name,value in values[0].items():
                actual=values[1][name];delta=value.astype(np.float64)-actual.astype(np.float64)
                metrics[name]=dict(maxAbs=float(np.max(np.abs(delta))),relativeL2=float(np.linalg.norm(delta.ravel())/max(np.linalg.norm(value.astype(np.float64).ravel()),1e-30)),finite=bool(np.isfinite(actual).all()),shape=list(actual.shape))
        status='PASS' if len(values)==2 and all(x['maxAbs']==0 and x['finite'] for x in metrics.values()) else 'FAIL'
        receipt['models'][role]=dict(status=status,runs=runs,outputs=metrics)
        a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(receipt,indent=2)+'\n')
    receipt['status']='PASS_HOST_PARITY' if all(v['status']=='PASS' for v in receipt['models'].values()) else 'FAIL_HOST_PARITY'
    a.output.write_text(json.dumps(receipt,indent=2)+'\n')

if __name__=='__main__':main()
# Purpose: isolate native compiler/model contexts during parity. Upstream frozen/function-extraction graphs; Python3.11/CoreML9/macOS27.2, generated2026-10-05 America/New_York. New validation file; no source graph edits.
