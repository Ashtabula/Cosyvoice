# run_enumerated_ane_matrix.py
# Requirement: run fail-closed frozen-byte placement matrix on the specified iPhone; continue after variant failure.
from __future__ import annotations
import argparse
import hashlib
import json
import re
import statistics
import subprocess
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
IOS = REPO / 'ios'
ROLES = ['llmPrefill', 'llmDecode', 'conditions', *[f'flow{i}' for i in range(6)], 'hift', 'speechTokenizer', 'campPlus']
BASE = {r: ('CPU_AND_GPU' if r in ['conditions', 'hift'] or r.startswith('flow') else 'CPU_ONLY') for r in ROLES}

def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--asset-root', type=Path, required=True)
    p.add_argument('--output', type=Path, default=IOS / '.work/ane-optimization')
    p.add_argument('--receipt', type=Path, default=IOS / 'validation/evidence/enumerated_ane_optimization.json')
    p.add_argument('--only', nargs='*')
    p.add_argument('--repeats', type=int, default=0)
    args = p.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    export = json.loads((args.asset_root / 'enumerated-production-export-receipt.json').read_text())
    prior = json.loads(args.receipt.read_text()) if args.receipt.exists() else {}
    data = prior or dict(schemaVersion=1, status='RUNNING', baselineSourceCommit='782e79cdd455f71c5430f1256bd69253a0b0a2c2', sourceCommit=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(), frozenAsset=dict(profile=export['profile'],payloadTreeSha256=export['payloadTreeSha256'],assetExportSourceCommit=export['sourceCommit'],payloadBytes=export['payloadBytes']), historicalBaseline=dict(coldRTF=3.063966,warmRTF=0.913861,placement=BASE), variants=[], productionPromotion=False, residencyEvidence='requested placement only, residency not proven')
    data["sourceCommit"] = subprocess.check_output(["git","rev-parse","HEAD"],text=True).strip()
    variants = [('A-baseline', []), ('B-prefill-ne', ['llmPrefill']), ('C-decode-ne', ['llmDecode']), ('D-llm-ne', ['llmPrefill','llmDecode']), ('E-conditions-ne', ['conditions'])]
    variants += [(f'F-flow{i}-ne', [f'flow{i}']) for i in range(6)]
    variants += [('H-hift-ne', ['hift']), ('J-tokenizer-ne', ['speechTokenizer']), ('J-campplus-ne', ['campPlus'])]
    def run_variant(name, ne, attempt=0):
        placement = {**BASE, **{r:'CPU_AND_NE' for r in ne}}
        out = args.output / (name if attempt == 0 else name+f"-thermal-attempt{attempt}")
        command = ['python3',str(IOS/'validation/run_enumerated_production_device.py'),'--asset-root',str(args.asset_root),'--device','00008150-000A05CA1440401C','--reference-wav','/Volumes/WD/Codes/dub/dub_ios/ios/ExpressionHeadToHead/GeneratedAssets/leijun-1.wav','--reference-transcript','/Volumes/WD/Codes/dub/dub_ios/ios/ExpressionHeadToHead/GeneratedAssets/leijun-1.txt','--host-receipt',str(IOS/'.work/reference-release/coreml/reference_host_parity_receipt.json'),'--output',str(out),'--team','H5R282PV62','--reuse-staging','--wait-thermal-nominal','--reset-reference-conditioning','--skip-build','--skip-variable-smoke','--diagnostic-enumerated-compute','cpu-gpu','--timeout','600']
        for r in ne: command += ['--placement',r+':CPU_AND_NE']
        out.mkdir(parents=True,exist_ok=True)
        print(f'[ANE-MATRIX] START {name} {placement}',flush=True)
        completed = out/'candidate-benchmark-receipt.json'
        cached = json.loads(completed.read_text()) if completed.exists() else {}
        if name == 'A-baseline' and cached.get('signedHostBuildSourceCommit') == data['sourceCommit'] and cached.get('requestedComputePlacementByRole') == placement and cached.get('status') == 'PASS_CANDIDATE_BENCHMARK':
            code = 0
            print('[ANE-MATRIX] using exact completed initial baseline receipt',flush=True)
        else:
            with (out/'host-run.log').open('a') as log:
                child=subprocess.Popen(command,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
                for line in child.stdout:
                    log.write(line);log.flush();print(line,end='',flush=True)
                code=child.wait()
        receipt_path=out/'candidate-benchmark-receipt.json'
        raw=json.loads(receipt_path.read_text()) if receipt_path.exists() else {}
        console=(out/'candidate-benchmark-console.log').read_text() if (out/'candidate-benchmark-console.log').exists() else ''
        stages=re.findall(r'\[COSY-VALIDATION-STAGE\] (.*)',console)
        phases=[]
        for line in console.splitlines():
            if '[COSY-ACOUSTIC-PHASE] ' in line:
                try: phases.append(json.loads(line.split('[COSY-ACOUSTIC-PHASE] ',1)[1]))
                except json.JSONDecodeError: pass
        loads=[dict(stage=m[0],milliseconds=float(m[1])) for m in re.findall(r'\[COSY-MODEL-LOAD\] stage=(\S+) ms=([0-9.eE+-]+)',console)]
        row=dict(name=name,requestedPlacement=placement,returnCode=code,status=raw.get('status','HOST_FAILURE'),deviceReceipt=raw,stageTimings=dict(acousticPhases=phases,modelLoads=loads),lastStage=stages[-1] if stages else None,consoleSha256=hashlib.sha256(console.encode()).hexdigest(),hostLog=str(out/'host-run.log'),residencyEvidence='requested placement only, residency not proven')
        if raw.get('status')=='PASS_CANDIDATE_BENCHMARK':
            good=raw.get('signedHostBuildSourceCommit')==raw.get('sourceCommit') and raw.get('deviceModelIdentifier')=='iPhone18,4' and raw.get('systemVersion')=='27.2' and raw.get('firstSamples')==249600 and raw.get('repeatSamples')==249600 and raw.get('sampleRate')==24000 and raw.get('flowSteps')==6 and raw.get('validationSamplerSeed')==42 and raw.get('matchedDeterministicWav') and raw.get('thermalStart')=='nominal' and raw.get('payloadTreeSha256')==data['frozenAsset']['payloadTreeSha256'] and raw.get('requestedComputePlacementByRole')==placement
            row['comparable']=bool(good and raw.get('thermalPeak') not in ['serious','critical'])
            if not good: row['status']='FAIL_COMPARABILITY_GATE'
        else: row['comparable']=False
        if 'requires thermal nominal' in str(raw.get('error','')):
            row['failureClassification']='THERMAL_START_REJECTED_NOT_MODEL_FAILURE'
            data.setdefault('thermalRejectedAttempts',[]).append(row)
        data.setdefault('previousAttempts',[]).extend(r for r in data['variants'] if r['name']==name)
        data['variants']=[r for r in data['variants'] if r['name']!=name]+[row]
        write(args.receipt,data)
        print(f"[ANE-MATRIX] FINISH {name} status={row['status']} warmRTF={raw.get('repeatRTF')} lastStage={row['lastStage']}",flush=True)
        if row.get('failureClassification')=='THERMAL_START_REJECTED_NOT_MODEL_FAILURE' and attempt<20:
            print('[ANE-MATRIX] cooling 15 seconds, retrying strict nominal-start gate',flush=True)
            time.sleep(15)
            return run_variant(name,ne,attempt+1)
        return row
    for name,ne in variants:
        if args.only is None or name in args.only:
            existing=next((r for r in data['variants'] if r['name']==name),None)
            if not existing or existing.get("deviceReceipt",{}).get("sourceCommit") != subprocess.check_output(["git","rev-parse","HEAD"],text=True).strip() or existing.get("status") not in ["PASS_CANDIDATE_BENCHMARK", "FAIL_COMPARABILITY_GATE"]: run_variant(name,ne)
    if args.only is None:
        baseline=next((r['deviceReceipt'].get('repeatRTF') for r in data['variants'] if r['name']=='A-baseline' and r.get('comparable')),0.913861)
        accepted=[r['name'].split('-')[1] for r in data['variants'] if r['name'].startswith('F-flow') and r.get('comparable') and r['deviceReceipt']['repeatRTF']<=baseline*1.05]
        if accepted:
            run_variant('G-mixed-flow-ne',accepted)
        else:
            data['adaptiveVariants']=dict(G='no eligible stable Flow NE requests')
        stable=[]
        for name,ne in variants:
            if name != 'A-baseline' and any(r['name']==name and r.get('comparable') for r in data['variants']):
                stable.extend(ne)
        if stable: run_variant('I-maximum-requested-ne',sorted(set(stable)))
        else: data.setdefault('adaptiveVariants',{})['I']='no eligible independent NE requests'
    if args.repeats:
        winners=sorted([r for r in data['variants'] if r.get('comparable') and '-repeat' not in r['name']],key=lambda r:r['deviceReceipt']['repeatRTF'])[:3]
        for winner in winners:
            ne=[r for r,v in winner['requestedPlacement'].items() if v=='CPU_AND_NE']
            for i in range(1,args.repeats+1): run_variant(winner['name']+f'-repeat{i}',ne)
        data['medianWarmRTF']={w['name']:statistics.median([r['deviceReceipt']['repeatRTF'] for r in data['variants'] if r.get('comparable') and r['name'].startswith(w['name']+'-repeat')]) for w in winners if any(r.get('comparable') and r['name'].startswith(w['name']+'-repeat') for r in data['variants'])}
    data['status']='PLACEMENT_MATRIX_RECORDED_DIAGNOSTIC_PHASES_PENDING'
    write(args.receipt,data)

if __name__=='__main__': main()
# Purpose: durable fail-closed A-J placement matrix, exact workload gates and nominal-only median repeats.
# Upstream: run_enumerated_production_device.py public Engine benchmark; upstream purpose signed frozen-asset replay.
# Environment: macOS/Xcode/Python3 + physical iPhone18,4 iOS27.2. Generated 2026-10-05 America/New_York.
# New file: role matrix, error continuation, source/asset identity, per-component logs and requested-only residency labels.
