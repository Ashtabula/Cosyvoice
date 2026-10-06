# run_equivalent_final_matrix.py
# Requirement: physical controlled unchanged-math matrix, independent failures retained.
from pathlib import Path
import argparse, json, subprocess, time, traceback
import run_enumerated_production_device as device

ROOT = Path(__file__).resolve().parents[2]
IOS = ROOT / 'ios'
DEVICE = '00008150-000A05CA1440401C'
BUNDLE = 'com.actacomes.cosyvoice3.candidatebenchmark'

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--phase', choices=['performance', 'plans'], required=True)
    parser.add_argument('--case', action='append', default=[])
    parser.add_argument('--reuse-compiled-caches', action='store_true')
    parser.add_argument('--tag', default='final')
    args = parser.parse_args()
    destination = IOS / ('.work/equivalent-optimization/' + args.tag + '-matrix')
    destination.mkdir(parents=True, exist_ok=True)
    baseline = json.loads((IOS / '.work/equivalent-optimization/baseline-input-bound/candidate-benchmark-receipt.json').read_text())
    rows = []
    target = IOS / ('validation/evidence/equivalent_' + args.tag + '_' + args.phase + '.json')
    def save():
        target.write_text(json.dumps(dict(schemaVersion=1, phase=args.phase, rows=rows, promotion=False), indent=2) + '\n')
    if args.phase == 'plans':
        roles = ['conditions', *['flow' + str(i) for i in range(6)], 'hift']
        for name, single in [('multifunction', False), ('single-function-diagnostic', True), ('multifunction-gpu-plan', False), ('llm-ne-plan', False)]:
            output = destination / name
            output.mkdir(exist_ok=True)
            row = dict(name=name, scope='diagnostic only; plans are not measured residency')
            try:
                selected_roles = ['llmPrefill', 'llmDecode'] if name == 'llm-ne-plan' else roles
                options = ['--ane-compute-plans'] + ['--validation-plan-role=' + role for role in selected_roles]
                if name == 'multifunction-gpu-plan':
                    options += ['--validation-placement=' + role + ':CPU_AND_GPU' for role in roles]
                if single:
                    options += ['--validation-single-function=' + role for role in roles]
                started = time.time()
                process = device.launch_with_console(DEVICE, BUNDLE, output / 'console.log', options)
                row['receipt'] = device.wait_receipt(device=DEVICE, bundle=BUNDLE, filename='ane-compute-plan-receipt.json', output=output, process=process, started=started, timeout=900)
                row['status'] = 'COLLECTED'
            except Exception as error:
                row.update(status='FAIL', error=str(error), traceback=traceback.format_exc())
            rows.append(row); save()
            print('[FINAL-MATRIX]', name, row['status'], flush=True)
        return
    cases = [
        ('control-6-none', 6, 'none', False, False),
        ('partition2-selected', 2, 'selected-family', False, False),
        ('partition3-selected', 3, 'selected-family', False, False),
        ('partition1-te', 1, 'selected-family', False, True),
        ('idle-6-selected', 6, 'selected-family', True, False),
        ('partition2-hift-ne', 2, 'selected-family', False, False),
    ]
    for name, partition, cache, idle, te in cases:
        if args.case and name not in args.case:
            continue
        output = destination / name
        output.mkdir(exist_ok=True)
        command = ['python3', str(IOS / 'validation/run_enumerated_production_device.py'),
            '--asset-root', str(IOS / '.work/enumerated-n1-n450/generated-ac31e117938ed50132365973a103cc8425942700'),
            '--device', DEVICE, '--bundle', BUNDLE,
            '--reference-wav', '/Volumes/WD/Codes/dub/dub_ios/ios/ExpressionHeadToHead/GeneratedAssets/leijun-1.wav',
            '--reference-transcript', '/Volumes/WD/Codes/dub/dub_ios/ios/ExpressionHeadToHead/GeneratedAssets/leijun-1.txt',
            '--host-receipt', str(IOS / '.work/reference-release/coreml/reference_host_parity_receipt.json'),
            '--output', str(output), '--team', 'H5R282PV62', '--reuse-staging', '--skip-build',
            '--skip-variable-smoke', '--diagnostic-enumerated-compute', 'cpu-gpu',
            '--placement', 'llmPrefill:CPU_AND_NE', '--placement', 'llmDecode:CPU_AND_NE',
            '--acoustic-cache', cache, '--flow-partition', str(partition),
            '--sustained-count', '12', '--wait-thermal-nominal', '--capture-pcm', '--timeout', '900']
        if idle: command.append('--idle-readiness')
        if te: command.append('--materialize-te')
        if name == 'partition2-hift-ne': command += ['--placement', 'hift:CPU_AND_NE']
        if args.reuse_compiled_caches: command.append('--reuse-compiled-caches')
        row = dict(name=name, partition=partition, cache=cache, idleReadiness=idle, materializeExistingTE=te)
        try:
            with (output / 'host-console.log').open('w') as log:
                child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
                for line in child.stdout:
                    print(line, end='', flush=True); log.write(line); log.flush()
                row['returnCode'] = child.wait()
            receipt_path = output / 'candidate-benchmark-receipt.json'
            receipt = json.loads(receipt_path.read_text()) if receipt_path.exists() else {}
            same_inputs = all(receipt.get('inputIdentity', {}).get(key) == value for key, value in baseline['inputIdentity'].items() if key != 'runtimeRoot')
            exact = receipt.get('warmFloat32PCMSha256') == baseline['warmFloat32PCMSha256']
            valid = row['returnCode'] == 0 and same_inputs and exact and receipt.get('flowSteps') == 6 and receipt.get('repeatSamples') == 249600 and receipt.get('payloadTreeSha256') == baseline['payloadTreeSha256']
            row.update(receipt=receipt, sameActualInputs=same_inputs, physicalFloat32BitIdentical=exact, status='PASS_EQUIVALENT_PHYSICAL' if valid else 'FAIL_OR_NOT_COMPARABLE')
        except Exception as error:
            row.update(status='FAIL', error=str(error), traceback=traceback.format_exc())
        rows.append(row); save()
        print('[FINAL-MATRIX]', name, row['status'], row.get('receipt', {}).get('repeatRTF'), flush=True)

if __name__ == '__main__':
    main()
# Purpose: collect comparable performance and independent packaging/ANE diagnostics.
# Upstream: frozen schema-3 public device runner; Python3/macOS/Xcode/iPhone18,4.
# Generated 2026-10-05 20:57 EDT America/New_York; new file. No model/math changes.
