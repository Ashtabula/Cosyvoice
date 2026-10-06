# run_enumerated_persistent_cold_start.py
# Requirement: four independent public workloads, fresh-install-like A, actual kill/relaunch B, same-process C; continue failures.
from pathlib import Path
import argparse, json, subprocess, traceback

ROOT = Path(__file__).resolve().parents[2]
IOS = ROOT / 'ios'
TARGET = IOS / 'validation/evidence/enumerated_persistent_cold_start.json'
CASES = [
    ('n257_384', 'This is a CosyVoice3 public API reference voice validation.'),
    ('n001_128', 'This is a test.'),
    ('n129_256', 'This is a public reference voice test for today.'),
    ('n385_450', 'International communication requires professional preparation and accurate pronunciation during comprehensive experimental performance validation and mathematical precision on this physical phone.'),
]

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--functions', nargs='+', default=[x[0] for x in CASES])
    parser.add_argument('--partition', type=int, choices=[1,2,3,6], default=6)
    parser.add_argument('--tag', default='frozen-six')
    parser.add_argument('--cache', default='selected-family', choices=['none','small','decoder','selected-family'])
    args = parser.parse_args()
    evidence = json.loads(TARGET.read_text()) if TARGET.exists() else dict(schemaVersion=1,status='RUNNING',buckets=[],productionPromotion=False)
    for function, text in CASES:
        if function not in args.functions: continue
        row = dict(functionName=function,variant=args.tag,workloadText=text,lanes=[])
        for lane in ['FIRST_EVER_COLD','PROCESS_RELAUNCH_COLD']:
            output = IOS / '.work/persistent-cold' / args.tag / function / lane
            output.mkdir(parents=True,exist_ok=True)
            command = ['python3',str(IOS/'validation/run_enumerated_production_device.py'),
                '--asset-root',str(IOS/'.work/enumerated-n1-n450/generated-ac31e117938ed50132365973a103cc8425942700'),
                '--device','00008150-000A05CA1440401C','--team','H5R282PV62',
                '--reference-wav','/Volumes/WD/Codes/dub/dub_ios/ios/ExpressionHeadToHead/GeneratedAssets/leijun-1.wav',
                '--reference-transcript','/Volumes/WD/Codes/dub/dub_ios/ios/ExpressionHeadToHead/GeneratedAssets/leijun-1.txt',
                '--host-receipt',str(IOS/'.work/reference-release/coreml/reference_host_parity_receipt.json'),
                '--output',str(output),'--reuse-staging','--skip-build','--skip-variable-smoke',
                '--diagnostic-enumerated-compute','cpu-gpu','--placement','llmPrefill:CPU_AND_NE',
                '--placement','llmDecode:CPU_AND_NE','--acoustic-cache',args.cache,
                '--flow-partition',str(args.partition),'--workload-text',text,'--wait-thermal-nominal',
                '--capture-pcm','--timeout','900']
            if lane == 'PROCESS_RELAUNCH_COLD': command.append('--reuse-compiled-caches')
            result = dict(lane=lane,output=str(output),launchCommand=command,
                processRestart='devicectl --terminate-existing then fresh launch; PID must differ between A/B',
                resetAppManagedDerivedState=lane=='FIRST_EVER_COLD',CoreMLSystemCacheCleared=False)
            try:
                with (output/'host-console.log').open('w') as log:
                    child = subprocess.Popen(command,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
                    for line in child.stdout: print(line,end='',flush=True);log.write(line);log.flush()
                    result['returnCode'] = child.wait()
                receipt = output/'candidate-benchmark-receipt.json'
                result['receipt'] = json.loads(receipt.read_text()) if receipt.exists() else {}
                r = result['receipt']; actual = r.get('enumeratedAcousticExecution',{})
                result['status'] = 'PASS_ACTUAL_BUCKET_PUBLIC_API' if result['returnCode']==0 and actual.get('firstFunctionName')==function and actual.get('repeatFunctionName')==function else 'FAIL_OR_WRONG_ACTUAL_BUCKET'
            except Exception as error:
                result.update(status='FAIL',error=str(error),traceback=traceback.format_exc())
            row['lanes'].append(result)
            evidence['status']='RUNNING';TARGET.write_text(json.dumps(evidence|{'activeBucket':row},indent=2)+'\n')
            print('[PERSISTENT-COLD]',function,lane,result['status'],result.get('receipt',{}).get('firstSynthesisMilliseconds'),flush=True)
        a,b = [x.get('receipt',{}) for x in row['lanes']]
        same_input = all(a.get('inputIdentity',{}).get(k)==v for k,v in b.get('inputIdentity',{}).items() if k!='runtimeRoot') and bool(a.get('inputIdentity'))
        row['actualProcessIDs']=[a.get('processID'),b.get('processID')]
        row['actualRestartProven']=bool(a.get('processID')) and a.get('processID') != b.get('processID')
        row['sameActualInputIdentity']=same_input
        row['Float32PCMUnchangedAcrossRestart']=a.get('warmFloat32PCMSha256')==b.get('firstFloat32PCMSha256')==b.get('warmFloat32PCMSha256') and bool(a.get('warmFloat32PCMSha256'))
        row['status']='PASS_RESTART_REUSE_WORKLOAD_GATE' if all(x['status'].startswith('PASS_') for x in row['lanes']) and row['actualRestartProven'] and same_input and row['Float32PCMUnchangedAcrossRestart'] and a.get('validationCacheReset') is True and b.get('validationCacheReset') is False else 'FAIL_RESTART_GATE'
        evidence['buckets'].append(row); evidence.pop('activeBucket',None)
        TARGET.write_text(json.dumps(evidence,indent=2)+'\n')
    evidence['status']='RECORDED_PHYSICAL_RESTART_CASES_IDLE_AND_FINAL_ANALYSIS_PENDING'
    TARGET.write_text(json.dumps(evidence,indent=2)+'\n')

if __name__ == '__main__': main()
# Purpose: immutable same-bucket A/B/C with actual process evidence and no implicit reset.
# Upstream frozen public SDK/runner; Python3/macOS/Xcode/iPhone18,4. Generated2026-10-05 America/New_York; new file.
