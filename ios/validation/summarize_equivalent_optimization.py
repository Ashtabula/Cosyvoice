# summarize_equivalent_optimization.py
# Requirement: preserve failed candidates; recommend only actually input-bound, PCM-identical physical runs.
from pathlib import Path
import hashlib, json, statistics, subprocess
from datetime import datetime
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parents[2]
IOS = ROOT / 'ios'
EVIDENCE = IOS / 'validation/evidence'
WORK = IOS / '.work/equivalent-optimization'

def load(path):
    return json.loads(path.read_text())

def identity_matches(a, b):
    return all(a.get(key) == value for key, value in b.items() if key != 'runtimeRoot')

def main():
    baseline = load(WORK / 'baseline-input-bound/candidate-benchmark-receipt.json')
    export = load(EVIDENCE / 'equivalent_flow_partition_export.json')
    graph_audit = load(EVIDENCE / 'enumerated_ane_graph_audit.json')
    rows = []
    rank = dict(nominal=0, fair=1, serious=2, critical=3)
    paths = list(WORK.rglob('candidate-benchmark-receipt.json')) + list((IOS/'.work/persistent-cold').rglob('candidate-benchmark-receipt.json'))
    for path in sorted(paths):
        if 'coreai-profile' in path.parts:
            continue  # Instrumented diagnostics are never performance comparisons.
        receipt = load(path)
        if receipt.get('status') != 'PASS_CANDIDATE_BENCHMARK':
            continue
        relative = path.relative_to(IOS).as_posix()
        stages = receipt['repeatStages']
        sustained = receipt.get('sustainedRuns', [])
        execution = receipt.get('enumeratedAcousticExecution', {})
        valid_workload = (identity_matches(receipt.get('inputIdentity', {}), baseline['inputIdentity'])
            and receipt.get('payloadTreeSha256') == baseline['payloadTreeSha256']
            and receipt.get('deviceModelIdentifier') == baseline['deviceModelIdentifier']
            and receipt.get('systemVersion') == baseline['systemVersion']
            and receipt.get('validationSamplerSeed') == 42 and receipt.get('flowSteps') == 6
            and receipt.get('sampleRate') == 24000 and receipt.get('repeatSamples') == 249600
            and execution.get('repeatN') == 260 and execution.get('repeatFunctionName') == 'n257_384'
            and receipt.get('playbackDuringBenchmark') is False and receipt.get('thermalStart') == 'nominal')
        pcm = (receipt.get('warmFloat32PCMSha256') == baseline['warmFloat32PCMSha256']
            and receipt.get('firstFloat32PCMSha256') == baseline['firstFloat32PCMSha256'])
        confounded = relative == '.work/equivalent-optimization/final-matrix/control-6-none/candidate-benchmark-receipt.json'
        phases = []
        console = path.with_name('candidate-benchmark-console.log')
        if console.exists():
            for line in console.read_text().splitlines():
                if '[COSY-ACOUSTIC-PHASE] ' in line:
                    phases.append(json.loads(line.split('[COSY-ACOUSTIC-PHASE] ', 1)[1]))
        row = dict(path=relative, receipt=receipt, actualInputWorkloadMatches=valid_workload,
            physicalFloat32PCMBitIdentical=pcm, usablePerformance=valid_workload and pcm and not confounded,
            status='PASS_EQUIVALENT_PHYSICAL' if valid_workload and pcm else 'REJECTED',
            timingConfound='concurrent device diagnostic package readback; excluded, separate recheck required' if confounded else None,
            warmRTF=receipt['repeatRTF'], warmTotalMilliseconds=receipt['repeatSynthesisMilliseconds'],
            acousticLoadMilliseconds=stages['acousticModelLoadMilliseconds'],
            acousticExecuteMilliseconds=stages['acousticSynthesisMilliseconds'],
            sampledPeakMiB=receipt.get('sampledPeakPhysicalFootprintBytes', 0)/1024**2,
            acousticPhaseTimings=phases, packageIdentity=receipt.get('experimentalModelIdentity', {}))
        row['firstCallDefinition'] = receipt.get('coldLane',receipt.get('coldDefinition'))
        row['relaunchColdMilliseconds'] = receipt.get('firstSynthesisMilliseconds') if receipt.get('coldLane')=='PROCESS_RELAUNCH_COLD' else None
        row['relaunchColdRTF'] = receipt.get('firstRTF') if receipt.get('coldLane')=='PROCESS_RELAUNCH_COLD' else None
        if sustained:
            row['sustained'] = dict(count=len(sustained), medianRTF=statistics.median(x['RTF'] for x in sustained),
                worstRTF=max(x['RTF'] for x in sustained),
                peakThermal=max((x['thermalEnd'] for x in sustained), key=lambda value: rank[value]),
                seriousOrCriticalFraction=sum(rank[x['thermalEnd']] >= 2 for x in sustained)/len(sustained),
                firstSeriousIndex=next((x['index'] for x in sustained if rank[x['thermalEnd']] >= 2), None),
                interRequestDelay=False,
                medianProcessCPUMilliseconds=statistics.median(x['processCPUMilliseconds'] for x in sustained) if all('processCPUMilliseconds' in x for x in sustained) else None)
        rows.append(row)
    accepted = [row for row in rows if row['usablePerformance']]
    fastest = min(accepted, key=lambda row: row['warmRTF'])
    cool_candidates = [row for row in accepted if row.get('sustained', {}).get('count') == 12]
    coolest = min(cool_candidates, key=lambda row: (rank[row['sustained']['peakThermal']], row['sustained']['seriousOrCriticalFraction'], row['sustained']['medianProcessCPUMilliseconds'])) if cool_candidates else None
    b = baseline['repeatStages']
    optimized = fastest['receipt']['repeatStages']
    delta = dict(baseline='actual-input-bound f25a449 control; historical 0.5866 is informational',
        baselineWarmTotalMilliseconds=baseline['repeatSynthesisMilliseconds'], optimizedWarmTotalMilliseconds=fastest['warmTotalMilliseconds'],
        baselineAcousticLoadMilliseconds=b['acousticModelLoadMilliseconds'], optimizedAcousticLoadMilliseconds=optimized['acousticModelLoadMilliseconds'],
        baselineAcousticExecuteMilliseconds=b['acousticSynthesisMilliseconds'], optimizedAcousticExecuteMilliseconds=optimized['acousticSynthesisMilliseconds'],
        savedAcousticLoadMilliseconds=b['acousticModelLoadMilliseconds']-optimized['acousticModelLoadMilliseconds'],
        savedAcousticExecuteMilliseconds=b['acousticSynthesisMilliseconds']-optimized['acousticSynthesisMilliseconds'],
        savedTotalMilliseconds=baseline['repeatSynthesisMilliseconds']-fastest['warmTotalMilliseconds'],
        peakMemoryDeltaMiB=fastest['sampledPeakMiB']-baseline['sampledPeakPhysicalFootprintBytes']/1024**2)
    comparison = dict(status='FASTEST_MEASURED_EQUIVALENT', candidatePath=fastest['path'], warmRTF=fastest['warmRTF'],
        signedHostSourceCommit=fastest['receipt']['sourceCommit'], flowPartition=fastest['receipt'].get('flowPartition'),
        acousticCache=fastest['receipt'].get('acousticCacheStrategy'), sampledPeakMiB=fastest['sampledPeakMiB'],
        requestedPlacement=fastest['receipt']['requestedComputePlacementByRole'], observedResidency='not proven by MLComputeUnits',
        scope='experimental lossless repack/cache; frozen shipping Runtime untouched; four functions retained; not promotion')
    cold = dict(status='NOT_PROVEN_SUSTAINED_THERMAL_SUPERIORITY', provisionalLowestObservedPressureOnly=True, candidatePath=coolest['path'] if coolest else None,
        observations=coolest.get('sustained') if coolest else None,
        limitation='nominal/fair/serious are coarse OS states; app CPU excludes Core ML services/accelerator power. No claim of minimum sustained watts or causal thermal superiority.')
    data = dict(schemaVersion=2, status='COMPLETED_PHYSICAL_EXPERIMENTS_NO_PROMOTION',
        recordedAt=datetime.now(ZoneInfo('America/New_York')).isoformat(),
        evidenceAssemblyGitHead=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
        algorithmUnchanged=True, mathEquivalenceScope='original serialized operations, dtypes, casts and weight bytes preserved; host all four families plus physical N260 Float32 PCM controls',
        publicAPI='CosyVoice3Engine.synthesize()', baseline=baseline,
        frozenPayloadTreeSha256=baseline['payloadTreeSha256'], manifestSha256=baseline['inputIdentity']['manifestSha256'],
        sourcePackages={role:model['identity'] for role,model in graph_audit['models'].items()},
        sourcePackagePaths={role:model['path'] for role,model in graph_audit['models'].items()},
        optimizedPartitions=export, hostNumericalParity=[load(EVIDENCE/name) for name in ['equivalent_flow_partition_host_parity.json','equivalent_flow_partition_host_n129.json','equivalent_flow_te_materialization_host.json']],
        variants=rows, FASTEST_EQUIVALENT=comparison, COOLEST_EQUIVALENT=cold, acousticDelta=delta,
        historicalWarm05866=dict(totalMilliseconds=6100.706666, acousticLoadMilliseconds=544.12054, acousticExecuteMilliseconds=2022.962835, strictInputComparison='not established; preserved audit INVALID_COMPARISON'),
        coldInterpretation='First-call cache resets and referenceCacheHit/preparation fields are recorded per run; idle preparation is paid separately and never counted as raw cold improvement.',
        memoryMeasurement='app task_info phys_footprint sampled 1Hz, possible transient peaks and external compiler/service memory not included',
        productionPromotion=False, huggingFaceUpload=False, releaseCatalogChanged=False)
    if (EVIDENCE/'enumerated_persistent_cold_start.json').exists(): data['persistentColdStart']=load(EVIDENCE/'enumerated_persistent_cold_start.json')
    if (EVIDENCE/'enumerated_runtime_hints.json').exists(): data['runtimeHintExperiments']=load(EVIDENCE/'enumerated_runtime_hints.json')
    defaults = next((v for v in data.get('runtimeHintExperiments',{}).get('variants',[]) if v['name']=='six-default'),None)
    if defaults:
        receipts = [r['receipt'] for r in defaults['runs'] if r['status']=='PASS_FROZEN_PCM_EQUIVALENT']
        if receipts:
            data['recommendedRuntimeArchitecture'] = dict(flowPartition=6,asset='unchanged frozen schema3 multifunction four families',
                llmRequested='CPU_AND_NE',acousticRequested='CPU_AND_GPU',referenceRequested='CPU_ONLY',
                persistent='backup-excluded Application Support generic artifacts + model/function identities; authoritative native load at use',
                lifetime='bounded30s selected-family reuse; no LLM/KV-state reuse; idle other models released immediately',
                idle='serial nominal-only foreground/finite background window; persistent strict pending/ready per function',
                reason='new cohort six has fastest relaunch and essentially tied warm; p2 is lower-memory alternative with fastest historical single point; no promotion',
                relaunchColdMilliseconds=receipts[-1]['firstSynthesisMilliseconds'],warmRTFRange=[r['repeatRTF'] for r in receipts],
                peakMiBRange=[r['sampledPeakPhysicalFootprintBytes']/1024**2 for r in receipts],
                sustainedThermal='not solved; serious observed in continuous12 synthesis')
            data['relaunchCostBreakdown']=receipts[-1]['firstStages']
    for name in ['enumerated_persistent_idle.json','enumerated_idle_same_binary_relaunch.json','enumerated_idle_all_ready_relaunch.json']:
        if (EVIDENCE/name).exists():data[name.removesuffix('.json')]=load(EVIDENCE/name)
    (EVIDENCE/'enumerated_acoustic_equivalent_optimization.json').write_text(json.dumps(data,indent=2,sort_keys=True)+'\n')
    ane = load(EVIDENCE/'enumerated_ane_optimization.json')
    ane.update(status='COMPLETED_EQUIVALENT_RUNTIME_EXPERIMENTS', equivalentAcousticSummary=comparison, thermalSummary=cold, acousticDelta=delta)
    if 'recommendedRuntimeArchitecture' in data: ane['recommendedRuntimeArchitecture']=data['recommendedRuntimeArchitecture']
    for name in ['equivalent_final_plans.json','equivalent_single_device_readback.json','equivalent_instruments_residency.json','enumerated_runtime_hints.json','enumerated_persistent_cold_start.json','enumerated_persistent_idle.json']:
        if (EVIDENCE/name).exists():ane[name.removesuffix('.json')]=load(EVIDENCE/name)
    (EVIDENCE/'enumerated_ane_optimization.json').write_text(json.dumps(ane,indent=2,sort_keys=True)+'\n')
    print(json.dumps(dict(FASTEST_EQUIVALENT=comparison,COOLEST_EQUIVALENT=cold,delta=delta),indent=2))

if __name__ == '__main__':
    main()
# Purpose: explicit hash/workload/output gates and bounded observational recommendations.
# Upstream: immutable device receipts and lossless graph export. Python3.9+/macOS.
# Generated 2026-10-05 America/New_York; new file. No model/runtime mathematical changes.
