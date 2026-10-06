# run_resource_efficiency.py
# Requirement: frozen public resource screen or offline/unplugged paced comparison, exact evidence export.
from pathlib import Path
import argparse,subprocess,threading,time,json,hashlib
DEVICE='00008150-000A05CA1440401C';BUNDLE='com.actacomes.cosyvoice3.candidatebenchmark'
def copy(out,name):
 subprocess.run(['xcrun','devicectl','device','copy','from','--device',DEVICE,'--domain-type','appDataContainer','--domain-identifier',BUNDLE,'--source','Documents/'+name,'--destination',str(out/name)],check=True)
def collect(out,policy,mode):
 copy(out,'resource-efficiency-receipt.json')
 r=json.loads((out/'resource-efficiency-receipt.json').read_text())
 if r.get('status')!='PASS_FROZEN_RESOURCE_RUN':
  print('[RESOURCE] incomplete/failure receipt preserved',r.get('status'),flush=True)
  return r
 assert r['cachePolicy']==policy and r['mode']==mode and r['SHARDS']==2 and r['flowSteps']==6
 copy(out,'resource-efficiency-events.jsonl');copy(out,'resource-efficiency.wav')
 assert hashlib.sha256((out/'resource-efficiency.wav').read_bytes()).hexdigest()==r['WAV_SHA256']=='a04f69c7d01e08bc779c8a49dafa6fd7723397cf3da6864060f17f8d68277888'
 for row in r['rows']:
  assert row['PCM_SHA256']=='909a1b85650b172604fb2d39b6a35f8f3b5cbf80bd97beb76e775b73ee4cd694' and row['tokenSequenceSHA256']=='5227af1bfe2461b352e1d8747f63df8d54fd7b4c7640e001b81152a8b455a64d'
  assert row['sampleRate']==24000 and row['samples']==249600 and row['N']==260
 return r
def main():
 p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--mode',choices=['screen','continuous'],required=True);p.add_argument('--policy',choices=['selected-family','decoder','none'],required=True);p.add_argument('--collect-only',action='store_true');p.add_argument('--allow-charging',action='store_true');p.add_argument('--chunks',type=int,default=60);a=p.parse_args()
 a.output.mkdir(parents=True,exist_ok=True)
 if a.collect_only:
  collect(a.output,a.policy,a.mode);return
 flags=['--no-playback','--validation-resource-run',f'--validation-resource-lane={a.mode}',f'--validation-resource-chunks={a.chunks}','--validation-flow-partition=2',f'--validation-acoustic-cache={a.policy}']
 if a.allow_charging:flags+=['--validation-resource-allow-charging']
 cmd=['xcrun','devicectl','device','process','launch','--device',DEVICE,'--terminate-existing']
 if a.mode=='screen':cmd+=['--console']
 cmd += [BUNDLE,'--',*flags]
 binding={'command':cmd,'runnerSHA256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),'sourceGitHEAD':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),'virtualConsumption':'one chunk ahead /24kHz PCM clock, not physical speaker proof','formalUnpluggedRequired':not a.allow_charging,'noDeviceReadbackDuringFormal':True}
 (a.output/'host-binding.json').write_text(json.dumps(binding,indent=2)+'\n')
 print('[RESOURCE] launch',cmd,flush=True)
 if a.mode=='continuous':
  subprocess.run(cmd,check=True)
  print('[RESOURCE] offline app will prime, then require nominal and ' + ('explicit CHARGING conditions' if a.allow_charging else 'unplugged conditions') + '; no console dependency. Collect only after UI PASS with --collect-only.',flush=True)
  return
 proc=subprocess.Popen(cmd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,bufsize=1);done=threading.Event()
 def read():
  with (a.output/'console.log').open('w') as f:
   for line in proc.stdout:
    print(line,end='',flush=True);f.write(line);f.flush()
    if '[COSY-AUTO-DONE]' in line:done.set()
 threading.Thread(target=read,daemon=True).start();deadline=time.monotonic()+600
 while not done.wait(30):
  print('[RESOURCE] screen pending; no timed readback',flush=True)
  if proc.poll() is not None or time.monotonic()>deadline:raise RuntimeError('screen ended/timeout; no fabricated result')
 r=collect(a.output,a.policy,a.mode)
 assert r.get('status')=='PASS_FROZEN_RESOURCE_RUN',r
if __name__=='__main__':main()
# Purpose: short-screen and10-20min offlinepaced launch/export; neverresetcache/modifymodel.
# Upstream existing DeviceSmoke resource lane, Python3/macOS/Xcode/iPhone18,4; generated2026-10-06.
# Formal mode launchhasno remoteconsole dependency; userunplug handling, dataonlypulledaftercompletion.
