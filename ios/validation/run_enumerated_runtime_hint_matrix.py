# run_enumerated_runtime_hint_matrix.py
# Requirement: unchanged packages/math runtime hints and lossless partitions; exact PCM gate and two independent process launches per configuration.
from pathlib import Path
import argparse,json,subprocess,traceback
ROOT=Path(__file__).resolve().parents[2];IOS=ROOT/'ios'
CASES=[('six-default',6,[]),('two-default',2,[]),('three-default',3,[]),
       ('six-infrequent',6,['--enumerated-infrequent-reshape']),
       ('six-fast',6,['--enumerated-fast-prediction']),
       ('six-both',6,['--enumerated-fast-prediction','--enumerated-infrequent-reshape'])]
def main():
 p=argparse.ArgumentParser();p.add_argument('--cases',nargs='+',default=[x[0] for x in CASES]);a=p.parse_args()
 target=IOS/'validation/evidence/enumerated_runtime_hints.json';data=json.loads(target.read_text()) if target.exists() else dict(schemaVersion=1,status='RUNNING',variants=[],promotion=False)
 for name,partition,flags in CASES:
  if name not in a.cases:continue
  row=dict(name=name,partition=partition,hints=flags,runs=[])
  for index in range(2):
   out=IOS/'.work/persistent-cold/runtime-hints'/name/str(index);out.mkdir(parents=True,exist_ok=True)
   cmd=['python3',str(IOS/'validation/run_enumerated_production_device.py'),'--asset-root',str(IOS/'.work/enumerated-n1-n450/generated-ac31e117938ed50132365973a103cc8425942700'),
        '--device','00008150-000A05CA1440401C','--team','H5R282PV62',
        '--reference-wav','/Volumes/WD/Codes/dub/dub_ios/ios/ExpressionHeadToHead/GeneratedAssets/leijun-1.wav',
        '--reference-transcript','/Volumes/WD/Codes/dub/dub_ios/ios/ExpressionHeadToHead/GeneratedAssets/leijun-1.txt',
        '--host-receipt',str(IOS/'.work/reference-release/coreml/reference_host_parity_receipt.json'),
        '--output',str(out),'--reuse-staging','--skip-build','--skip-variable-smoke','--reuse-compiled-caches',
        '--diagnostic-enumerated-compute','cpu-gpu','--placement','llmPrefill:CPU_AND_NE','--placement','llmDecode:CPU_AND_NE',
        '--acoustic-cache','selected-family','--flow-partition',str(partition),'--wait-thermal-nominal','--capture-pcm',*flags]
   item=dict(index=index,scope='first use of configuration on existing artifacts' if index==0 else 'actual process relaunch, identical configuration',output=str(out))
   try:
    with (out/'host-console.log').open('w') as log:
     child=subprocess.Popen(cmd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
     for line in child.stdout:print(line,end='',flush=True);log.write(line);log.flush()
     code=child.wait()
    r=json.loads((out/'candidate-benchmark-receipt.json').read_text()) if (out/'candidate-benchmark-receipt.json').exists() else {}
    exact=r.get('firstFloat32PCMSha256')==r.get('warmFloat32PCMSha256')=='909a1b85650b172604fb2d39b6a35f8f3b5cbf80bd97beb76e775b73ee4cd694'
    item.update(returnCode=code,receipt=r,status='PASS_FROZEN_PCM_EQUIVALENT' if code==0 and exact and r.get('repeatSamples')==249600 and r.get('flowSteps')==6 else 'FAIL_OR_PCM_CHANGED')
   except Exception as error:item.update(status='FAIL',error=str(error),traceback=traceback.format_exc())
   row['runs'].append(item);target.write_text(json.dumps(data|{'activeVariant':row},indent=2)+'\n');print('[RUNTIME-HINT]',name,index,item['status'],item.get('receipt',{}).get('repeatRTF'),flush=True)
  row['actualProcessRestartProven']=row['runs'][0].get('receipt',{}).get('processID')!=row['runs'][1].get('receipt',{}).get('processID') and bool(row['runs'][0].get('receipt',{}).get('processID'))
  data['variants'].append(row);data.pop('activeVariant',None);target.write_text(json.dumps(data,indent=2)+'\n')
 data['status']='RECORDED_RUNTIME_HINT_AND_PARTITION_PHYSICAL_GATES';target.write_text(json.dumps(data,indent=2)+'\n')
if __name__=='__main__':main()
# Purpose controlled alternative constructor/execution hints, no algorithm or model conversion.
# Upstream public physical runner; Python3/macOS/Xcode/iPhone18,4. Generated2026-10-05 America/New_York; new file.
