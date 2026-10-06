# run_enumerated_idle_bootstrap.py
# Requirement: one first public PCM then thermal-gated serial idle preparation; preserve progress and actual relaunch evidence.
from pathlib import Path
import json, subprocess, time, traceback
import run_enumerated_production_device as device

ROOT=Path(__file__).resolve().parents[2];IOS=ROOT/'ios'
D='00008150-000A05CA1440401C';B='com.actacomes.cosyvoice3.candidatebenchmark'

def main():
    output=IOS/'.work/persistent-cold/idle-bootstrap';output.mkdir(parents=True,exist_ok=True)
    target=IOS/'validation/evidence/enumerated_persistent_idle.json'
    data=dict(schemaVersion=1,status='RUNNING',scope='first PCM return then foreground idle/finite background window; no additional prediction/sampler warming',progress=[],promotion=False)
    def save():target.write_text(json.dumps(data,indent=2)+'\n')
    try:
        started=time.time()
        options=['--validation-idle-bootstrap','--no-playback','--reset-cosy-cache','--validation-cold-lane=FIRST_EVER_COLD',
                 '--validation-enumerated-cpu-gpu','--validation-placement=llmPrefill:CPU_AND_NE','--validation-placement=llmDecode:CPU_AND_NE',
                 '--validation-acoustic-cache=selected-family','--validation-flow-partition=6']
        data['launchArguments']=options;save()
        process=device.launch_with_console(D,B,output/'bootstrap-console.log',options)
        data['bootstrap']=device.wait_receipt(device=D,bundle=B,filename='persistent-bootstrap-receipt.json',output=output,process=process,started=started,timeout=600);save()
        last=None
        while time.time()-started<1200:
            time.sleep(10)  # Host receipt polling only; device preparation is event-driven.
            try:
                device.copy_from(D,B,'Documents/persistent-idle-receipt.json',output/'persistent-idle-receipt.json')
                snapshot=json.loads((output/'persistent-idle-receipt.json').read_text())
                if snapshot.get('recordedAtUnix',0)<started-2:continue
                states=snapshot.get('bucketStates',[])
                key=(snapshot.get('status'),snapshot.get('thermalState'),tuple((x['functionName'],x['ready']) for x in states))
                if key!=last:
                    data['progress'].append(snapshot);last=key;save();print('[IDLE-BOOTSTRAP]',key,flush=True)
                if snapshot.get('status')=='PASS_ALL_FOUR_BUCKETS_LOAD_READY':
                    data['status']='PASS_IDLE_CURRENT_FOUR_BUCKET_IDENTITIES_LOAD_READY';data['completed']=snapshot;save();break
                if str(snapshot.get('status','')).startswith('FAIL'):
                    data['status']='FAIL_IDLE';data['failure']=snapshot;save();break
            except subprocess.CalledProcessError as error:print('[IDLE-BOOTSTRAP] receipt pending',error,flush=True)
            if process.poll() is not None:raise RuntimeError('idle app ended; inspect complete bootstrap console')
        else:data['status']='PENDING_OS_THERMAL_WINDOW_TIMEOUT';save()
    except Exception as error:
        data.update(status='FAIL',error=str(error),traceback=traceback.format_exc());save()
    print('[IDLE-BOOTSTRAP] FINAL',data['status'],flush=True)

if __name__=='__main__':main()
# Purpose: observable persistent idle progression without suppressing failures or faking background permission.
# Upstream SDK/physical runner; Python3/macOS/Xcode/iPhone18,4. Generated2026-10-05 America/New_York; new file.
