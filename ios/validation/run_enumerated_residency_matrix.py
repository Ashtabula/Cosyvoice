# run_enumerated_residency_matrix.py
# Requirement: serialized physical stage/placement comparisons, preserve every failure, no readback during timed loops.
from pathlib import Path
import argparse,json,subprocess,sys,traceback
ROOT=Path(__file__).resolve().parents[2]
CASES={}
for partition in [2,3,6,1]:
    for policy in ['CPU_AND_GPU','CPU_AND_NE']:
        CASES[f'plan-flow-p{partition}-{policy}']=['--mode','plan','--partition',str(partition),*sum((['--role',f'flow{i}','--placement',f'flow{i}:{policy}'] for i in range(partition)),[])]
for stage in ['llm','flow','hift']:
    for policy in ['CPU_ONLY','CPU_AND_GPU','CPU_AND_NE']:
        roles=['llmPrefill','llmDecode'] if stage=='llm' else (['flow0','flow1'] if stage=='flow' else ['hift'])
        CASES[f'{stage}-{policy}']=['--mode','isolated','--stage',stage,'--partition','2' if stage=='flow' else '6',*sum((['--placement',f'{role}:{policy}'] for role in roles),[])]
CASES['flow-p3-CPU_AND_GPU']=['--mode','isolated','--stage','flow','--partition','3',*sum((['--placement',f'flow{i}:CPU_AND_GPU'] for i in range(3)),[])]
CASES['hift-static-CPU_AND_NE']=['--mode','isolated','--stage','hift','--placement','hift:CPU_AND_NE','--single-function','hift','--static-n260']
for partition in [2,3,6]:
    CASES[f'full-p{partition}']=['--mode','full','--partition',str(partition)]
    CASES[f'full-p{partition}-hift-CPU_AND_NE']=['--mode','full','--partition',str(partition),'--placement','hift:CPU_AND_NE']
CASES['flow-p6-CPU_ONLY']=['--mode','isolated','--stage','flow','--partition','6',*sum((['--placement',f'flow{i}:CPU_ONLY'] for i in range(6)),[])]

def main():
    p=argparse.ArgumentParser();p.add_argument('--cases',nargs='+',required=True);a=p.parse_args()
    output=ROOT/'ios/.work/ane-residency/matrix';output.mkdir(parents=True,exist_ok=True)
    index=output/'matrix-index.json';value=json.loads(index.read_text()) if index.exists() else dict(schemaVersion=1,runs=[])
    for name in a.cases:
        if name not in CASES:raise ValueError('unknown case '+name)
        target=output/name
        if target.exists():raise ValueError('never overwrite prior case '+name)
        target.mkdir()
        command=[sys.executable,str(ROOT/'ios/validation/run_enumerated_residency_probe.py'),'--output',str(target),'--timeout','180' if name.startswith('plan-') else '1800',*CASES[name]]
        row=dict(name=name,command=command)
        try:
            with (target/'host-console.log').open('w') as log:
                child=subprocess.Popen(command,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,bufsize=1)
                for line in child.stdout:print(line,end='',flush=True);log.write(line);log.flush()
                row['returnCode']=child.wait()
            evidence=target/'probe-receipt.json'
            row['probe']=json.loads(evidence.read_text()) if evidence.exists() else None
            row['status']='COLLECTED_NOT_AUTOMATIC_PASS' if row['returnCode']==0 else 'FAIL_PRESERVED_CONTINUE'
        except Exception as e:row.update(status='FAIL_PRESERVED_CONTINUE',error=str(e),traceback=traceback.format_exc())
        value['runs'].append(row);index.write_text(json.dumps(value,indent=2)+'\n')
        print('[RESIDENCY-MATRIX]',name,row['status'],flush=True)

if __name__=='__main__':main()
# Purpose: physical diagnostic matrix, not automatic production qualification. Upstream probe/native public request; Python3/macOS/Xcode/iPhone18,4. Generated2026-10-05 America/New_York. New file; failures retained and next case continues.
