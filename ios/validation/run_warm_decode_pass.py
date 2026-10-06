# run_warm_decode_pass.py
# Requirement: serial real-device public requests; collect memory/logits only after completion; no timed readback.
from pathlib import Path
import argparse,base64,hashlib,json,subprocess,threading,time
DEVICE='00008150-000A05CA1440401C';BUNDLE='com.actacomes.cosyvoice3.candidatebenchmark'

def main():
    p=argparse.ArgumentParser();p.add_argument('--mode',choices=['memory','repeat'],required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    out=a.output;out.mkdir(parents=True,exist_ok=True)
    flags=['--no-playback','--validation-warm-pass',f'--validation-warm-pass-mode={a.mode}','--validation-flow-partition=2','--validation-acoustic-cache=selected-family']
    if a.mode=='memory':flags+=['--validation-decode-audit']
    cmd=['xcrun','devicectl','device','process','launch','--device',DEVICE,'--terminate-existing','--console',BUNDLE,'--',*flags]
    print('[WARM-DECODE-PASS] SHARDS=2',cmd,flush=True)
    proc=subprocess.Popen(cmd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,bufsize=1);done=threading.Event()
    def consume():
        with (out/'console.log').open('w') as log:
            for line in proc.stdout:
                print(line,end='',flush=True);log.write(line);log.flush()
                if '[COSY-AUTO-DONE]' in line:done.set()
    threading.Thread(target=consume,daemon=True).start();deadline=time.monotonic()+600
    while not done.wait(30):
        print('[WARM-DECODE-PASS] waiting, no device readback',flush=True)
        if proc.poll() is not None or time.monotonic()>deadline:raise RuntimeError('device process ended/timeout; preserved console, no fabricated receipt')
    for name in ['warm-decode-pass-receipt.json','warm-decode-pass.wav']:
        subprocess.run(['xcrun','devicectl','device','copy','from','--device',DEVICE,'--domain-type','appDataContainer','--domain-identifier',BUNDLE,'--source','Documents/'+name,'--destination',str(out/name)],check=True)
    r=json.loads((out/'warm-decode-pass-receipt.json').read_text());assert r['status']=='PASS_BIT_IDENTICAL_WARM_PASS' and r['SHARDS']==2 and r['flowSteps']==6
    assert hashlib.sha256((out/'warm-decode-pass.wav').read_bytes()).hexdigest()==r['WAV_SHA256']
    for i,item in enumerate(r['persistentRuntime']['validationWarmPassRecords']):
        audit=item.get('audit',{})
        if audit.get('logitsFP16Base64'):
            blob=base64.b64decode(audit['logitsFP16Base64']);(out/f'request-{i+1}-logits.f16').write_bytes(blob)
            audit['fixtureSHA256']=hashlib.sha256(blob).hexdigest()
        (out/f'request-{i+1}-tokens.json').write_text(json.dumps(item['tokens'])+'\n')
    (out/'host-collection.json').write_text(json.dumps(dict(command=cmd,runnerSHA256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),noTimedReadback=True,SHARDS=2,receiptSHA256=hashlib.sha256((out/'warm-decode-pass-receipt.json').read_bytes()).hexdigest()),indent=2)+'\n')
    print('[WARM-DECODE-PASS] complete',out,flush=True)
if __name__=='__main__':main()
# Purpose: hash-bound PhaseA memory and baseline warm-repeat collection; upstream native warm lane.
# Python3/macOS/Xcode/iPhone; generated2026-10-06. No cold cache reset, placement/graph/shard/Flow change.
