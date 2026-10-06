# summarize_enumerated_residency.py
# Requirement: exact provenance, measured stage/pipeline thermal and conservative residency conclusions; retain failures and reject changed endpoint controls.
from pathlib import Path
import collections,hashlib,json,re,statistics,subprocess
import numpy as np
ROOT=Path(__file__).resolve().parents[2];EVIDENCE=ROOT/'ios/validation/evidence';WORK=ROOT/'ios/.work/ane-residency'
GOLD='909a1b85650b172604fb2d39b6a35f8f3b5cbf80bd97beb76e775b73ee4cd694'
PAYLOAD='4750dba5e727276d22b71399b702a33597aaaf36d61edf8cc3dd8bd3897e6efa'

def load(path):return json.loads(path.read_text()) if path.exists() else {}
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def thermal(rows):
    return dict(start=rows[0].get('thermalStart') if rows else None,end=rows[-1].get('thermalEnd') if rows else None,
                firstFairIteration=next((i+1 for i,r in enumerate(rows) if r.get('thermalEnd')=='fair'),None),
                firstSeriousIteration=next((i+1 for i,r in enumerate(rows) if r.get('thermalEnd') in ['serious','critical']),None),
                counts=dict(collections.Counter(r.get('thermalEnd') for r in rows)))

def main():
    index=load(WORK/'matrix/matrix-index.json');signed=set();stages=[];full=[];failures=[];plans=[]
    original=np.fromfile(ROOT/'ios/.work/persistent-cold/runtime-hints/six-default/1/candidate-warm.f32',np.float32)
    pcm_metrics={GOLD:dict(status='BIT_IDENTICAL',maxAbs=0.,relativeL2=0.)}
    for run in index.get('runs',[]):
        folder=WORK/'matrix'/run['name'];request=load(folder/'isolated-request-receipt.json')
        if request.get('sourceCommit'):signed.add(request['sourceCommit'])
        output=folder/'isolated-output.f32'
        if request.get('status')=='PASS_DIAGNOSTIC_REQUEST' and output.exists():
            actual=np.fromfile(output,np.float32)
            if actual.shape==original.shape:
                delta=actual.astype(np.float64)-original.astype(np.float64);maximum=float(np.max(np.abs(delta)));relative=float(np.linalg.norm(delta)/np.linalg.norm(original.astype(np.float64)))
                pcm_metrics[sha(output)]=dict(status='BIT_IDENTICAL' if maximum==0 else ('PASS_NORMAL_NUMERICAL_TOLERANCE' if maximum<=3e-4 and relative<=3e-4 else 'REJECT_CHANGED_ENDPOINT'),maxAbs=maximum,relativeL2=relative,tolerance=dict(atol=3e-4,relativeL2=3e-4),meaning='same PCM sample alignment; backend FP32 rounding accepted under explicit normal tolerance, not bit identity')
        for path in folder.glob('isolated-*-receipt.json'):
            if path.name=='isolated-request-receipt.json':continue
            receipt=load(path);rows=receipt.get('iterations',[])
            if receipt.get('processID')!=request.get('processID') or request.get('status')!='PASS_DIAGNOSTIC_REQUEST':continue
            stable=rows[1:];stage=dict(case=run['name'],receiptPath=str(path),receiptSHA256=sha(path),receipt=receipt,request=request,
                                   numericalEndpoint=pcm_metrics.get(request.get('Float32PCMSha256'),dict(status='UNKNOWN')),thermal=thermal(rows),
                                   firstMilliseconds=rows[0].get('wallMilliseconds') if rows else None,warmMedianMilliseconds=statistics.median(x['wallMilliseconds'] for x in stable) if stable else None,
                                   warmMedianSelfCPUTimeMilliseconds=statistics.median(x['CPUTimeMilliseconds'] for x in stable) if stable else None,
                                   actualResidency='UNKNOWN_RESIDENCY',acceleratorActivityDuringUnprofiledRun=None)
            stages.append(stage)
        path=folder/'candidate-benchmark-receipt.json';receipt=load(path)
        if receipt.get('sourceCommit'):signed.add(receipt['sourceCommit'])
        if receipt.get('status')=='PASS_CANDIDATE_BENCHMARK':
            rows=receipt.get('sustainedRuns',[]);metric=pcm_metrics.get(receipt.get('warmFloat32PCMSha256'),dict(status='UNKNOWN'))
            exact=receipt.get('repeatSamples')==249600 and receipt.get('sampleRate')==24000 and receipt.get('flowSteps')==6 and receipt.get('payloadTreeSha256')==PAYLOAD and len(rows)==12 and rows[0]['thermalStart']=='nominal'
            full.append(dict(case=run['name'],receiptPath=str(path),receiptSHA256=sha(path),receipt=receipt,numericalEndpoint=metric,
                             eligibleEquivalent=exact and metric['status'] in ['BIT_IDENTICAL','PASS_NORMAL_NUMERICAL_TOLERANCE'],warmRTF=receipt['repeatRTF'],
                             steadyMedianRTF=statistics.median(x['RTF'] for x in rows),steadyWorstRTF=max(x['RTF'] for x in rows),thermal=thermal(rows),
                             requestedPlacement=receipt.get('requestedRolePlacements'),actualPerOpResidency='UNKNOWN_RESIDENCY'))
        path=folder/'ane-compute-plan-receipt.json'
        if path.exists():plans.append(dict(case=run['name'],receiptSHA256=sha(path),receipt=load(path),meaning='preferred/supported only; not actual residency'))
        if run.get('status')=='FAIL_PRESERVED_CONTINUE' or (request and request.get('status')!='PASS_DIAGNOSTIC_REQUEST'):
            console=folder/'console.log';lines=console.read_text().splitlines() if console.exists() else []
            failures.append(dict(case=run['name'],orchestrationStatus=run.get('status'),request=request,consoleSHA256=sha(console) if console.exists() else None,lastConsoleLines=lines[-25:],
                                 phase='model construction before Flow prediction' if run['name']=='flow-CPU_ONLY' else None,
                                 cause='UNKNOWN; signal9 alone is not Jetsam attribution' if run['name']=='flow-CPU_ONLY' else None))
    common=dict(schemaVersion=1,recordedGitHEAD=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),physicalSignedSourceCommits=sorted(signed),
                device='iPhone18,4',iOS='27.2',assetExportSourceCommit='ac31e117938ed50132365973a103cc8425942700',frozenPayloadTreeSHA256=PAYLOAD,
                manifestSHA256='2ddc7fa084fb0e458b34f61af7fcc927773fb3697496a17f8ae1593ba33b56ee',promotion=False,algorithmWeightsAndFlowStepsUnchanged=True,
                persistentCacheAndNominalSerialIdlePreserved=True,publicAPI='CosyVoice3Engine.synthesize()',N=260,T=822,G=520,functionName='n257_384',sampleRate=24000,samples=249600,seconds=10.4)
    eligible=[r for r in full if r['eligibleEquivalent']]
    fastest=min(eligible,key=lambda r:r['warmRTF']) if eligible else None
    coolest=min(eligible,key=lambda r:((13-r['thermal']['firstSeriousIteration']) if r['thermal']['firstSeriousIteration'] else 0,r['steadyMedianRTF'])) if eligible else None
    thermal_evidence=dict(common,status='RECORDED_PHYSICAL_SUSTAINED_COMPARISONS_WITH_LIMITATIONS',isolatedStages=stages,fullPipelines=full,failures=failures,
                         FASTEST_EQUIVALENT=fastest['case'] if fastest else None,
                         COOLEST_EQUIVALENT_OBSERVED= coolest['case'] if coolest else None,
                         COOLEST_EQUIVALENT='NOT_PROVEN_SUSTAINED_COOL',
                         limitations=['Nominal indicator is coarse; residual first-use heat/system compiler work can affect attribution','Isolated12 groups have unequal elapsed duration, cannot compare temperature per equal joule/time','Self CPU excludes CoreML services, GPU and ANE power','First profiledLLM12 nominal vs laterunprofiled12 serious retained, not merged','No sleep/throttle between measured iterations; only pre-group nominal gate',
                                      'Unprofiled accelerator activity UNKNOWN; separate traces are evidence for traced configurations only'])
    (EVIDENCE/'enumerated_ane_thermal_attribution.json').write_text(json.dumps(thermal_evidence,indent=2)+'\n')
    traces=[load(EVIDENCE/'enumerated_ane_llm_trace_attribution.json'),load(EVIDENCE/'enumerated_ane_hift_trace_attribution.json')]
    residency=dict(common,status='ACTIVITY_PROVEN_FULL_PER_OP_RESIDENCY_NOT_PROVEN',classifications=dict(llmPrefill='UNKNOWN_RESIDENCY',llmDecode='UNKNOWN_RESIDENCY',Flow='UNKNOWN_RESIDENCY',HiFT='UNKNOWN_RESIDENCY'),
                   FULL_ANE_COMPONENTS=[],PARTIAL_ANE_COMPONENTS=[],NON_ANE_COMPONENTS=[],UNKNOWN_COMPONENTS=['LLM prefill','LLM decode','Flow','HiFT'],
                   observations=dict(LLM='Exact compiled artifact/PID/native intervals join12prefill and3108decode ANE hardware predictions; graph op mapping remains unavailable',
                                     Flow='CPU and GPU Request partitions measured in frozen6trace; anticipated root cast/shape/cast CPU preferred in p2/p3plans, actual per-op mapping absent',
                                     HiFT='Exact static-input diagnostic requestedNE trace12CPU prediction events, no matching ANE predictions; original multifunction NE plan632CPUpreferred; not an impossibility proof'),
                   traces=traces,physicalPlans=plans,operationSignatureEvidence='enumerated_ane_operation_signatures.json',
                   rewrites=[dict(name='input descriptor only staticN260',status='REJECT_COMPILE_INPUT_TYPE_MISMATCH'),dict(name='static program inputtypes',status='FLOW_REJECT_NUMERICAL_OR_CONTROL_FAILURE_HIFT_DIAGNOSTIC_ONLY'),dict(name='single enumerated shape',status='REJECT_HOST_COMPILE_OR_PREDICTION_FAILURE')],
                   graphOrCompilerCausalFallbackBlockers='UNKNOWN; no unsupported operator inferred solely from preferred device',actualFallbackOpLatencyMilliseconds=None,
                   officialPreferredDefinition='https://developer.apple.com/documentation/coreml/mlcomputeplandeviceusage',failures=failures)
    (EVIDENCE/'enumerated_ane_residency.json').write_text(json.dumps(residency,indent=2)+'\n')
    current=load(EVIDENCE/'enumerated_ane_optimization.json');current['actualResidencyAndThermalPhase']=dict(common,status=residency['status'],residencyEvidence='enumerated_ane_residency.json',thermalEvidence='enumerated_ane_thermal_attribution.json',FASTEST_EQUIVALENT=fastest,COOLEST_EQUIVALENT='NOT_PROVEN_SUSTAINED_COOL',bestObservedThermalCase=coolest['case'] if coolest else None)
    (EVIDENCE/'enumerated_ane_optimization.json').write_text(json.dumps(current,indent=2)+'\n')
    print('[RESIDENCY-SUMMARY] stages',len(stages),'full',len(full),'fastest',fastest['case'] if fastest else None,'warmRTF',fastest['warmRTF'] if fastest else None,'coolestObserved',coolest['case'] if coolest else None,flush=True)

if __name__=='__main__':main()
# Purpose: reproducible source/physical/evidence separation. Upstream hash-bound diagnostic receipts; Python3.11/numpy/macOS, generated2026-10-06 America/New_York. New summarizer; no model writes or promotion; UNKNOWN is explicit.
