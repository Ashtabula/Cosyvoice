# run_equivalent_cache_matrix.py
# Requirement: frozen graph/weight cache comparison, input SHA and deterministic output gates; continue failed variants.
from pathlib import Path
import argparse,json,re,subprocess,time
ROOT=Path(__file__).resolve().parents[2];IOS=ROOT/'ios'
def main():
 p=argparse.ArgumentParser();p.add_argument('--strategies',nargs='+',default=['small','decoder','selected-family']);a=p.parse_args()
 base=json.loads((IOS/'.work/equivalent-optimization/baseline-input-bound/candidate-benchmark-receipt.json').read_text())
 target=IOS/'validation/evidence/enumerated_acoustic_equivalent_optimization.json'
 data=json.loads(target.read_text()) if target.exists() else dict(schemaVersion=1,status='RUNNING',scope='algorithm unchanged; frozen model bytes; cache/runtime/placement/partition only',frozenPayloadTreeSha256=base['payloadTreeSha256'],baseline=base,variants=[],productionPromotion=False)
 for strategy in a.strategies:
  out=IOS/'.work/equivalent-optimization'/('cache-'+strategy);out.mkdir(parents=True,exist_ok=True)
  cmd=['python3',str(IOS/'validation/run_enumerated_production_device.py'),'--asset-root',str(IOS/'.work/enumerated-n1-n450/generated-ac31e117938ed50132365973a103cc8425942700'),'--device','00008150-000A05CA1440401C','--reference-wav','/Volumes/WD/Codes/dub/dub_ios/ios/ExpressionHeadToHead/GeneratedAssets/leijun-1.wav','--reference-transcript','/Volumes/WD/Codes/dub/dub_ios/ios/ExpressionHeadToHead/GeneratedAssets/leijun-1.txt','--host-receipt',str(IOS/'.work/reference-release/coreml/reference_host_parity_receipt.json'),'--output',str(out),'--team','H5R282PV62','--reuse-staging','--skip-build','--skip-variable-smoke','--diagnostic-enumerated-compute','cpu-gpu','--placement','llmPrefill:CPU_AND_NE','--placement','llmDecode:CPU_AND_NE','--acoustic-cache',strategy,'--wait-thermal-nominal','--reset-reference-conditioning','--sustained-count','3','--timeout','900']
  print('[EQUIVALENT-CACHE] START',strategy,flush=True)
  with (out/'host-console.log').open('w') as log:
   child=subprocess.Popen(cmd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
   for line in child.stdout:print(line,end='',flush=True);log.write(line);log.flush()
   code=child.wait()
  rp=out/'candidate-benchmark-receipt.json';receipt=json.loads(rp.read_text()) if rp.exists() else {}
  good=receipt.get('status')=='PASS_CANDIDATE_BENCHMARK' and receipt.get('inputIdentity')==base['inputIdentity'] and receipt.get('payloadTreeSha256')==base['payloadTreeSha256'] and receipt.get('warmFloat32PCMSha256')==base['warmFloat32PCMSha256'] and receipt.get('repeatSamples')==249600 and receipt.get('flowSteps')==6
  console=(out/'candidate-benchmark-console.log').read_text() if (out/'candidate-benchmark-console.log').exists() else ''
  phases=[]
  for line in console.splitlines():
   if '[COSY-ACOUSTIC-PHASE] ' in line:
    try:phases.append(json.loads(line.split('[COSY-ACOUSTIC-PHASE] ',1)[1]))
    except ValueError:pass
  row=dict(strategy=strategy,status='PASS_FROZEN_BIT_IDENTICAL' if good else 'FAIL_OR_NOT_COMPARABLE',returnCode=code,receipt=receipt,acousticPhases=phases,algorithmUnchanged=True,modelBytesChanged=False,flowPartition=[0,1,2,3,4,5],residency='requested placement only, residency not proven',sustainedInterRequestDelay=False)
  data['variants'].append(row);target.write_text(json.dumps(data,indent=2,sort_keys=True)+'\n')
  print('[EQUIVALENT-CACHE] FINISH',strategy,row['status'],receipt.get('repeatRTF'),flush=True)
 data['status']='CACHE_MATRIX_RECORDED_PARTITION_AND_PLACEMENT_PENDING';target.write_text(json.dumps(data,indent=2,sort_keys=True)+'\n')
if __name__=='__main__':main()
# Purpose: compare bounded cache lifetimes with identical public API output/input identity.
# Upstream: frozen public benchmark; environment Python3/macOS/Xcode/physical iPhone. Generated2026-10-05 America/New_York; new file.
