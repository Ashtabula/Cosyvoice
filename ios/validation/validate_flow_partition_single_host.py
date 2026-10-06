# validate_flow_partition_single_host.py
# Requirement: exact selected n257_384 single-function partition parity on frozen conditioning/noise; fresh CPU process for every package prediction.
from pathlib import Path
import argparse,json,subprocess,sys
import numpy as np
import coremltools as ct

def main():
    p=argparse.ArgumentParser();p.add_argument('--asset-root',type=Path,required=True);p.add_argument('--partitions',type=Path,required=True);p.add_argument('--single-root',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    m=json.loads((a.asset_root/'cosyvoice3_enumerated.json').read_text());c=m['enumeratedAcoustic'];tmp=Path('/private/tmp/cosy-partition-single-host');tmp.mkdir(exist_ok=True)
    prompt=np.fromfile(a.asset_root/c['defaultPromptTokens'],np.int32).reshape(1,151);feat=np.fromfile(a.asset_root/c['defaultPromptFeat'],np.float32).reshape(1,302,80);speaker=np.fromfile(a.asset_root/c['defaultSpeaker'],np.float32).reshape(1,192)
    model=ct.models.MLModel(str(a.asset_root/m['flowConditions']),function_name='n257_384',compute_units=ct.ComputeUnit.CPU_ONLY)
    condition=model.predict(dict(tokens=np.resize(prompt,(1,260)).astype(np.int32),prompt_tokens=prompt,prompt_feat=feat,speaker=speaker))
    noise=np.fromfile(a.asset_root/c['flowNoiseMaximum'],np.float32).reshape(1,80,1202)[:,:,:822]
    mask=np.ones((2,1,822),np.float32);start=dict(x=np.ascontiguousarray(np.concatenate([noise,noise],axis=0)),mask=mask,mu=condition['mu'].copy(),spks=condition['spks'].copy(),cond=condition['cond'].copy(),t=np.array([.25,.25],np.float32))
    child=Path(__file__).with_name('validate_ane_static_isolated_host.py');receipt=dict(schemaVersion=1,N=260,T=822,functionName='n257_384',scope='host components from frozen conditioning/noise, one Flow evaluation t0.25; no physical endpoint/solver parity claim',models=[])
    for count in [2,3]:
        feed=start.copy()
        for index in range(count):
            inputs=tmp/f'p{count}-{index}-input.npz';np.savez(inputs,**feed);values=[];runs=[]
            for label,package,function in [('multifunction',a.partitions/f'p{count}/group-{index}.mlpackage','n257_384'),('single',a.single_root/f'p{count}/flow{index}.mlpackage',None)]:
                output=tmp/f'p{count}-{index}-{label}.npz'
                if output.exists():output.unlink()
                command=[sys.executable,str(child),'--child','--package',str(package),'--input',str(inputs),'--prediction',str(output)]
                if function:command+=['--function',function]
                result=subprocess.run(command,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT);print('[FLOW-SINGLE-HOST]',count,index,label,result.returncode,result.stdout,flush=True)
                runs.append(dict(variant=label,returnCode=result.returncode,console=result.stdout))
                if output.exists():
                    with np.load(output) as data:values.append({k:data[k].copy() for k in data.files})
            metrics={k:dict(maxAbs=float(np.max(np.abs(values[0][k].astype(np.float64)-values[1][k].astype(np.float64)))),finite=bool(np.isfinite(values[1][k]).all())) for k in values[0]} if len(values)==2 else {}
            status='PASS' if len(values)==2 and all(v['maxAbs']==0 and v['finite'] for v in metrics.values()) else 'FAIL'
            receipt['models'].append(dict(partition=count,role=f'flow{index}',status=status,outputs=metrics,runs=runs))
            a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(receipt,indent=2)+'\n')
            if len(values)<1:break
            value=values[0]
            if 'h' in value:feed=dict(h=value['h'],te=value['te'],mask=mask)
            elif 'h_out' in value:feed['h']=value['h_out']
    receipt['status']='PASS_HOST_SELECTED_FUNCTION_PARITY' if len(receipt['models'])==5 and all(v['status']=='PASS' for v in receipt['models']) else 'FAIL_HOST_SELECTED_FUNCTION_PARITY'
    a.output.write_text(json.dumps(receipt,indent=2)+'\n')

if __name__=='__main__':main()
# Purpose: avoid attributing multifunction specialization errors to different graphs. Upstream unchanged partition/frozen programs; Python3.11/coremltools9/macOSCPU, generated2026-10-06 America/New_York. New diagnostic validation; no asset overwrite.
