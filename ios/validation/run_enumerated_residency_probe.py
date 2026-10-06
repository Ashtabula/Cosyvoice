# run_enumerated_residency_probe.py
# Requirement: launch the hash-bound installed diagnostic app, wait on console completion, copy evidence only after timed work has finished.
from pathlib import Path
import argparse, json, subprocess, threading, time, hashlib, signal

DEVICE = '00008150-000A05CA1440401C'
BUNDLE = 'com.actacomes.cosyvoice3.candidatebenchmark'

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--mode', choices=['isolated','plan','full'], required=True)
    parser.add_argument('--stage', choices=['llm','flow','hift'])
    parser.add_argument('--partition', type=int, choices=[1,2,3,6], default=2)
    parser.add_argument('--placement', action='append', default=[])
    parser.add_argument('--single-function', action='append', default=[])
    parser.add_argument('--role', action='append', default=[])
    parser.add_argument('--plan-directory', choices=['ANEFlowP2','ANEFlowP3'])
    parser.add_argument('--profile', action='store_true')
    parser.add_argument('--sustained-count', type=int, choices=range(21), default=0)
    parser.add_argument('--static-n260', action='store_true')
    parser.add_argument('--timeout', type=int, default=1200)
    args = parser.parse_args()
    if args.mode == "plan" and args.timeout == 1200: args.timeout = 180
    if args.mode == "isolated" and args.stage == "flow" and any(value.startswith("flow") and value.endswith(":CPU_AND_NE") for value in args.placement): args.timeout = min(args.timeout, 240)
    args.output.mkdir(parents=True, exist_ok=True)
    flags = ['--no-playback','--validation-acoustic-cache=selected-family',f'--validation-flow-partition={args.partition}']
    if args.mode == 'isolated':
        if not args.stage: parser.error('--stage required')
        flags += ['--validation-isolated-request',f'--validation-isolated-stage={args.stage}']
        files = ['isolated-request-receipt.json',f'isolated-{args.stage}-receipt.json','isolated-output.f32']
    elif args.mode == 'plan':
        flags += ['--ane-compute-plans'] + [f'--validation-plan-role={role}' for role in args.role]
        if args.plan_directory: flags += [f'--validation-plan-directory={args.plan_directory}']
        files = ['ane-compute-plan-receipt.json']
    else:
        flags += ['--candidate-benchmark','--validation-cold-lane=PROCESS_RELAUNCH_COLD',f'--validation-sustained-count={args.sustained_count}']
        files = ['candidate-benchmark-receipt.json','candidate-warm.f32','candidate-warm.wav']
    flags += [f'--validation-placement={value}' for value in args.placement]
    flags += [f'--validation-single-function={value}' for value in args.single_function]
    if args.static_n260:
        if not args.single_function: parser.error('static N260 requires explicit diagnostic single-function role')
        flags += ['--validation-static-n260']
    trace = None
    if args.profile:
        flags += ['--validation-stage-profiling']
        trace_path = Path('/private/tmp') / (args.output.name + '-CoreAI.trace')
        ready = threading.Event()
        trace = subprocess.Popen(['xcrun','xctrace','record','--template','Core AI','--instrument','Core ML','--instrument','Points of Interest',
                                  '--device',DEVICE,'--time-limit','1200s','--output',str(trace_path),'--all-processes'],
                                 stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,bufsize=1)
        def trace_output():
            with (args.output/'trace-console.log').open('w') as log:
                for line in trace.stdout:
                    print(line,end='',flush=True);log.write(line);log.flush()
                    if 'Recording' in line or 'recording' in line: ready.set()
        threading.Thread(target=trace_output,daemon=True).start()
        if not ready.wait(60): raise RuntimeError('trace did not report recording readiness; no performance run started')
    command = ['xcrun','devicectl','device','process','launch','--device',DEVICE,'--terminate-existing','--console',BUNDLE,'--',*flags]
    print(f'[RESIDENCY-PROBE] SHARDS={args.partition} launch',command,flush=True)
    process = subprocess.Popen(command,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,bufsize=1)
    done = threading.Event()
    def console_output():
        with (args.output/'console.log').open('w') as log:
            for line in process.stdout:
                print(line,end='',flush=True);log.write(line);log.flush()
                if '[COSY-AUTO-DONE]' in line: done.set()
    threading.Thread(target=console_output,daemon=True).start()
    deadline = time.monotonic()+args.timeout
    while not done.wait(30):
        print('[RESIDENCY-PROBE] waiting on completion console; no device readback',flush=True)
        if process.poll() is not None or time.monotonic()>deadline:
            if args.mode == 'plan':
                partial=args.output/'timeout-partial-plan.json'
                subprocess.run(['xcrun','devicectl','device','copy','from','--device',DEVICE,'--domain-type','appDataContainer','--domain-identifier',BUNDLE,'--source','Documents/ane-compute-plan-receipt.json','--destination',str(partial)])
                (args.output/'probe-timeout.json').write_text(json.dumps(dict(status='DIAGNOSTIC_TIMEOUT_OR_PROCESS_ENDED',elapsedSeconds=args.timeout,noResidencyInference=True,command=command),indent=2)+'\n')
            raise RuntimeError('app console ended or diagnostic deadline exceeded; no receipt treated as current PASS')
    if trace:
        trace.send_signal(signal.SIGINT)
        trace.wait()
    receipts = {}
    for name in files:
        destination = args.output/name
        result = subprocess.run(['xcrun','devicectl','device','copy','from','--device',DEVICE,'--domain-type','appDataContainer',
                                 '--domain-identifier',BUNDLE,'--source','Documents/'+name,'--destination',str(destination)])
        if result.returncode == 0:
            if destination.suffix in {'.f32','.wav'}:
                receipts[name]=dict(sha256=hashlib.sha256(destination.read_bytes()).hexdigest(),bytes=destination.stat().st_size);continue
            value=json.loads(destination.read_text())
            if args.mode == 'isolated' and name != 'isolated-request-receipt.json':
                parent=receipts.get('isolated-request-receipt.json',{}).get('receipt',{})
                if parent.get('status') != 'PASS_DIAGNOSTIC_REQUEST' or value.get('processID') != parent.get('processID'):
                    receipts[name]=dict(status='STALE_OR_FAILED_PARENT_EXCLUDED');continue
            receipts[name] = dict(sha256=hashlib.sha256(destination.read_bytes()).hexdigest(),receipt=value)
    identity = dict(schemaVersion=1,SHARDS=args.partition,command=command,receipts=receipts,profiled=args.profile,
                    noReadbackDuringTimedWork=True,actualResidency='UNKNOWN_RESIDENCY',
                    runnerSHA256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),hostGitHEAD=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip())
    (args.output/'probe-receipt.json').write_text(json.dumps(identity,indent=2)+'\n')
    print('[RESIDENCY-PROBE] evidence collected',flush=True)
    if trace:
        trace.wait()
        identity['traceReturnCode']=trace.returncode
        identity['tracePath']=str(trace_path)
        (args.output/'probe-receipt.json').write_text(json.dumps(identity,indent=2)+'\n')

if __name__ == '__main__': main()
# Purpose: physical diagnostic orchestration without readback interference. Upstream installed DeviceSmoke/native stage diagnostics; Python3/macOS/Xcode/iPhone18,4. Generated2026-10-05 America/New_York. New file; trace runs excluded from performance comparisons.

# Change2026-10-06: primary SHARDS2/default no sustained sweep; export original device WAV too.
# Upstream existing probe; Python3/macOS/Xcode; synthesis/math unchanged.
