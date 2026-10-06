# run_enumerated_listening_checkpoint.py
# Requirement: pull exact physical public-API SHARDS2 corpus WAVs to workspace; never claim human PASS.
from pathlib import Path
import argparse, hashlib, json, subprocess, threading, time, wave

DEVICE='00008150-000A05CA1440401C'
BUNDLE='com.actacomes.cosyvoice3.candidatebenchmark'

def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def command(args):
    print('[LISTENING]',args,flush=True)
    subprocess.run(args,check=True)

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--output',type=Path,default=Path('artifacts/listening/2shard/checkpoint_001'))
    parser.add_argument('--corpus',type=Path,default=Path('ios/validation/listening/corpus_v1.json'))
    args=parser.parse_args();out=args.output.resolve();out.mkdir(parents=True,exist_ok=True)
    if (out/'manifest.json').exists(): raise RuntimeError('checkpoint already exists: preserve it; choose a new directory')
    corpus=json.loads(args.corpus.read_text())
    assert corpus['shards']==2 and corpus['flowSteps']==6
    command(['xcrun','devicectl','device','copy','to','--device',DEVICE,'--domain-type','appDataContainer','--domain-identifier',BUNDLE,'--source',str(args.corpus.resolve()),'--destination','Documents/listening-corpus.json'])
    flags=['--no-playback','--validation-listening-checkpoint','--validation-flow-partition=2','--validation-acoustic-cache=selected-family']
    cmd=['xcrun','devicectl','device','process','launch','--device',DEVICE,'--terminate-existing','--console',BUNDLE,'--',*flags]
    print('[LISTENING] SHARDS=2 Flow=6 physical corpus start',flush=True)
    proc=subprocess.Popen(cmd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,bufsize=1)
    done=threading.Event()
    def consume():
        with (out/'device-console.log').open('w') as log:
            for line in proc.stdout:
                print(line,end='',flush=True);log.write(line);log.flush()
                if '[COSY-AUTO-DONE]' in line:done.set()
    threading.Thread(target=consume,daemon=True).start()
    deadline=time.monotonic()+1200
    while not done.wait(30):
        print('[LISTENING] waiting; no timed device readback',flush=True)
        if proc.poll() is not None or time.monotonic()>deadline:raise RuntimeError('device lane ended/timeout; inspect retained console')
    def pull(name,dst):
        command(['xcrun','devicectl','device','copy','from','--device',DEVICE,'--domain-type','appDataContainer','--domain-identifier',BUNDLE,'--source','Documents/'+name,'--destination',str(dst)])
    pull('listening-checkpoint-receipt.json',out/'device-receipt.json')
    receipt=json.loads((out/'device-receipt.json').read_text())
    assert receipt['status']=='PASS_DEVICE_CORPUS_PENDING_HUMAN'
    assert receipt['corpusSHA256']==sha(args.corpus) and receipt['SHARDS']==2 and receipt['flowSteps']==6
    assert len(receipt['samples'])==len(corpus['samples'])
    for item,expected in zip(receipt['samples'],corpus['samples']):
        assert item['id']==expected['id'] and item['text']==expected['text']
        dst=out/item['WAV'];pull(item['WAV'],dst)
        assert sha(dst)==item['WAV_SHA256']
        with wave.open(str(dst),'rb') as wav:
            assert wav.getframerate()==24000 and wav.getnchannels()==1 and wav.getnframes()==item['samples']
        item['workspaceWAV']=str(dst);item['exportVerified']=True
    receipt.update(workspaceArtifactDirectory=str(out),exportStatus='PASS_ALL_WAVS_ON_MAC_SHA_VERIFIED',humanListening='PENDING_HUMAN',LAST_KNOWN_GOOD=None,runnerSHA256=sha(Path(__file__)),launchCommand=cmd)
    (out/'manifest.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2)+'\n')
    print('[LISTENING] SHARDS=2 complete export; USER LISTENING REQUIRED:',out,flush=True)

if __name__=='__main__':main()
# Purpose: export original iPhone WAV bytes/receipts, checksum/count verification and pending human gate.
# Upstream DeviceSmoke public synthesis/WAV export; Python3/macOS/Xcode; generated2026-10-06 America/New_York.
# New file. No synthesis/model/algorithm/cache reset or playback behavior change.
