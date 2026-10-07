# validate_rebuilt_topology.py
# Requirement: independently check fresh native PID/stage/model-hash joins and bounded ANE prediction topology against the accepted methodology, preserving per-operation residency UNKNOWN.
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--capture', type=Path, required=True)
    parser.add_argument('--variant', choices=['baseline', 'q8', 'q4_hybrid'], required=True)
    parser.add_argument('--inventory', type=Path, required=True)
    parser.add_argument('--reuse-export', action='store_true')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    inventory = json.loads(args.inventory.read_text())
    profile = {'baseline': 'current', 'q8': 'q8', 'q4_hybrid': 'hybrid_q4'}[args.variant]
    receipt_path = args.capture / 'request' / f'llm-quantization-{args.variant}-receipt.json'
    receipt = json.loads(receipt_path.read_text())
    assert receipt['status'] == 'PASS_OBJECTIVE_SCREEN_PENDING_HUMAN'
    assert receipt['payloadTreeSHA256'] == inventory[profile]['payloadTreeSHA256']
    identities = {f'llm{role.capitalize()}': {'treeSha256': inventory[profile][role + 'SHA256']} for role in ['prefill', 'decode']}
    identity_path = args.capture / 'new-model-roles.json'
    identity_path.write_text(json.dumps(identities, indent=2) + '\n')
    prefix = args.capture / 'fresh'
    for schema in ['OSSignpostIntervals', 'coreml-os-signpost', 'ane-hw-intervals']:
        target = Path(str(prefix) + '-' + schema + '.xml')
        if args.reuse_export:
            assert target.is_file()
            continue
        assert not target.exists(), 'do not overwrite prior exported evidence'
        subprocess.run(['xcrun', 'xctrace', 'export', '--input', str(args.capture / 'new-models.trace'),
                        '--xpath', f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]',
                        '--output', str(target)], check=True)
    attribution = args.capture / 'attribution.json'
    subprocess.run([sys.executable, str(Path(__file__).with_name('analyze_quantized_llm_trace.py')),
                    '--prefix', str(prefix), '--request', str(receipt_path), '--output', str(attribution),
                    '--additional-model-identities', str(identity_path), '--engine-ios', str(root)], check=True)
    data = json.loads(attribution.read_text())
    old_path = {'baseline': 'llm_execution_audit_20261006/current_trace_attribution.json',
                'q8': 'llm_quantization_20261006/q8/execution_trace_attribution.json',
                'q4_hybrid': 'q4_compatibility_rescue_20261006/q4_hybrid/topology/execution_trace_attribution.json'}[args.variant]
    old = json.loads((root / 'validation/evidence' / old_path).read_text())
    rows = []
    assert len(receipt['rows']) == 5
    for role, expected in [('llmPrefill', 5), ('llmDecode', sum(r['N'] - 1 for r in receipt['rows']))]:
        matches = [m for m in data['models'] if m['role'] == role]
        assert len(matches) == 1, f'{role} actual process-load mapping missing/ambiguous'
        model = matches[0]
        historical = next(m for m in old['models'] if m['role'] == role)
        assert model['identity']['modelPackageSHA256'] == identities[role]['treeSha256']
        prediction_events = lambda counts: {k:v for k,v in counts.items() if not k.startswith('Load')}
        assert prediction_events(model['activityCounts']) == prediction_events(historical['activityCounts']), 'new CPU/partition activity or changed prediction topology'
        assert model['aneHardwarePredictionCount'] == expected
        assert model['anePredictionsContainedInCoreMLPrediction'] == expected
        stage = 'llm.prefill.prediction' if role == 'llmPrefill' else 'llm.decode.prediction'
        assert model['stageOverlapCounts'].get(stage) == expected, 'native PID stage containment incomplete'
        assert model['activityCounts'].get('CPU', 0) == 0
        rows.append(dict(role=role, packageSHA256=identities[role]['treeSha256'], compiledArtifact=model['compiledArtifact'],
                         predictions=expected, exactANEContainment=expected, cpuActivityEvents=0,
                         topologyEquivalentToAccepted=True, loadActivityCount=model['activityCounts'].get('Load (cached)', 0),
                         historicalLoadActivityCount=historical['activityCounts'].get('Load (cached)', 0)))
    out = dict(status='PASS_FRESH_HASH_PID_STAGE_BOUND_ANE_TOPOLOGY', profile=profile, processID=receipt['processID'],
               sourceCommit=receipt['sourceCommit'], rows=rows, historicalTraceReused=False,
               attributionSHA256=hashlib.sha256(attribution.read_bytes()).hexdigest(),
               actualPerOperationResidency='UNKNOWN_RESIDENCY',
               scope='No introduced coarse Core ML CPU activity/fragmentation; one hash-bound ANE hardware prediction per LLM prediction under native stage containment. Not 100% ANE or per-operation placement proof.')
    (args.capture / 'topology-gate.json').write_text(json.dumps(out, indent=2) + '\n')
    print('[NEW-TOPOLOGY]', json.dumps(out), flush=True)


if __name__ == '__main__':
    main()
# Purpose: fail-closed fresh physical topology gate. Upstream accepted analyze_quantized_llm_trace.py and original topology event counts.
# Environment: local macOS Python3.11/Instruments + signed iPhone public synthesis; generated2026-10-06 America/New_York. New file; no changed inference or tolerances.

# Gate diagnosis2026-10-06: Current six cached loads include one prepare/warm constructor plus five request loads; compare every prediction event exactly and report load lifecycle counts separately. No prediction/CPU/ANE containment tolerance change.
