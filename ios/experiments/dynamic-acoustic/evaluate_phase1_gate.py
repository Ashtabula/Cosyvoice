# evaluate_phase1_gate.py
# Requirement: fail closed before Phase2; execution success, numeric acceptance, physical backend policy and residency must remain distinct.
import argparse,json
from pathlib import Path

def main():
    p=argparse.ArgumentParser();p.add_argument('--conditions',type=Path,required=True);p.add_argument('--shard0',type=Path,required=True);p.add_argument('--fixed-control',type=Path,required=True);p.add_argument('--device-cpu',type=Path,required=True);p.add_argument('--device-ne',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    c,s,f,cpu,ne=[json.loads(x.read_text()) for x in (a.conditions,a.shard0,a.fixed_control,a.device_cpu,a.device_ne)]
    checks={}
    checks['conditionsSourceSymbolic']=c.get('symbolicDimensionRetained') is True
    checks['shard0SourceSymbolic']=s.get('symbolicDimensionRetained') is True
    checks['conditionsHostMultiLength']=c.get('status')=='PASS_HOST_SYMBOLIC_CONDITIONS' and {x['N'] for x in c['tests']}=={186,225}
    checks['shard0HostExecution']=s.get('conversion')==s.get('compilation')==s.get('loading')=='PASS' and all(x.get('finite') for x in s['tests'])
    # The frozen release validates Core ML sharded vs monolithic FP16 at max_abs=0, relative_l2=0.
    # Exact comparison to its accepted shard0 is the strict regression control at this probe boundary.
    checks['frozen225BitExactRegression']=all(x['dynamicVsFixed']['finite'] and x['dynamicVsFixed']['maxAbsError']==0 for x in f.values())
    for label,r in [('physicalCPUOnly',cpu),('physicalCPUAndNEPolicy',ne)]:
        checks[label]=r.get('physicalDevice') is True and {(x['role'],x['N']) for x in r.get('tests',[])}=={(role,n) for role in ('conditions','shard0') for n in (186,225)} and all(x.get('status')=='EXECUTED_NUMERICS_RECORDED_NOT_ACCEPTED' and all(m.get('finite') for m in x.get('outputs',{}).values()) for x in r.get('tests',[]))
    checks['sameAssetFamilyAcrossBackends']=cpu.get('assetIdentity',{}).get('models')==ne.get('assetIdentity',{}).get('models')
    result=dict(schemaVersion=1,status='PASS_PHASE1_GATE' if all(checks.values()) else 'FAIL_PHASE1_GATE',checks=checks,phase2Allowed=all(checks.values()),phase3Allowed=False,phase4Allowed=False,phase5Allowed=False,gateReason='Frozen225 numerical regression is not bit exact; do not interpret dynamic execution as numerical acceptance.',acceptanceSource='ios/validation/record_full_runtime_rebuild.py:98-101 (frozen Flow sharded vs monolithic FP16 max_abs=0, relative_l2=0)',residency='NOT_MEASURED',realLLM186Workload='NOT_RUN',fullDynamicPCM='NOT_RUN')
    a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
    return 0 if result['phase2Allowed'] else 1
if __name__=='__main__':raise SystemExit(main())
# Purpose: prevent unsupported promotion after shape-only proof while preserving CPU and accelerator-policy execution evidence.
# Upstream: fixed release record_full_runtime_rebuild.py and independent symbolic/physical receipts.
# Environment: local Python3.11; generated2026-10-03 America/New_York. New file, all lines.
