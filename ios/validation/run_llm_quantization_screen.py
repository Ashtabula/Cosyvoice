# run_llm_quantization_screen.py
# Requirement: paired frozen public physical screens and actual task-native WAV export, never quantized promotion.
import argparse,hashlib,json,subprocess,threading,time
from pathlib import Path
DEVICE='00008150-000A05CA1440401C';BUNDLE='com.actacomes.cosyvoice3.candidatebenchmark'
def main():
 p=argparse.ArgumentParser();p.add_argument('--variant',choices=['baseline','q8','q4','q4_hybrid'],required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--artifacts',type=Path,required=True);p.add_argument('--listening',action='store_true');p.add_argument('--profile-trace',action='store_true');p.add_argument('--sdk-profile-only',action='store_true');a=p.parse_args();runner_sha_at_launch=hashlib.sha256(Path(__file__).read_bytes()).hexdigest();a.output.mkdir(parents=True,exist_ok=True);a.artifacts.mkdir(parents=True,exist_ok=True)
 flags=['--no-playback','--validation-llm-quantization',f'--validation-llm-variant={a.variant}','--validation-warm-pass','--validation-execution-audit','--validation-flow-partition=2','--validation-acoustic-cache=selected-family']
 if a.variant=='q4_hybrid':flags+=['--validation-q4-hybrid-state-copy']
 if a.listening:flags=[x for x in flags if x not in ['--validation-llm-quantization','--validation-execution-audit']]+['--validation-llm-quantization-listening']
 if a.profile_trace:flags=['--validation-stage-profiling']+flags
 if a.sdk_profile_only:flags=[x for x in flags if x not in ['--validation-flow-partition=2','--validation-q4-hybrid-state-copy']]
 cmd=['xcrun','devicectl','device','process','launch','--device',DEVICE,'--terminate-existing','--console',BUNDLE,'--',*flags];proc=subprocess.Popen(cmd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,bufsize=1);done=threading.Event()
 def consume():
  with (a.output/'console.log').open('w') as f:
   for line in proc.stdout:
    print(line,end='',flush=True);f.write(line);f.flush()
    if '[COSY-AUTO-DONE]' in line:done.set()
 threading.Thread(target=consume,daemon=True).start();deadline=time.monotonic()+1200
 while not done.wait(30):
  print('[Q8-SCREEN] pending; no timed device readback',flush=True)
  if proc.poll() is not None or time.monotonic()>deadline:raise RuntimeError('screen incomplete; no fabricated receipt')
 def copy(name,dest):
  subprocess.run(['xcrun','devicectl','device','copy','from','--device',DEVICE,'--domain-type','appDataContainer','--domain-identifier',BUNDLE,'--source','Documents/'+name,'--destination',str(dest)],check=True)
 name=f'llm-quantization-{"listening-" if a.listening else ""}{a.variant}-receipt.json';copy(name,a.output/name);r=json.loads((a.output/name).read_text())
 if r.get('status')!=('PASS_DEVICE_LISTENING_PENDING_HUMAN' if a.listening else 'PASS_OBJECTIVE_SCREEN_PENDING_HUMAN'):raise RuntimeError('physicalscreenFAIL preserved '+json.dumps(r))
 assert r['SHARDS']==2 and r['flowSteps']==6 and r['variant']==a.variant
 artifacts=[]
 for row in (r['rows'] if a.listening else [{'WAV':r['WAVFilename'],'WAV_SHA256':r['WAV_SHA256']}]):
  wav=row['WAV'];copy(wav,a.artifacts/wav);assert hashlib.sha256((a.artifacts/wav).read_bytes()).hexdigest()==row['WAV_SHA256'];artifacts.append({'filename':wav,'path':str((a.artifacts/wav).resolve()),'sha256':row['WAV_SHA256']})
 record={'command':cmd,'runnerSHA256':runner_sha_at_launch,'physicalSourceCommit':r['sourceCommit'],'sourceGitHEADAtCollection':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),'artifactFilename':wav,'artifactAbsolutePath':str((a.artifacts/wav).resolve()),'artifacts':artifacts,'taskArtifactMechanism':'Codex native Markdown audio embed withabsolute localfile, displayedfilename notfilesystemnavigation','humanListening':'PENDING_HUMAN','charging':'screeningonly','noTimedReadback':True};(a.output/'host-collection.json').write_text(json.dumps(record,indent=2)+'\n');print('[Q8-SCREEN] artifactready',wav,flush=True)
if __name__=='__main__':main()
# Purpose: readable/exported exact WAV withvisibleaudiofilename; actualaudioembeddingisdoneinfinalresponse, not claimedbyprintingpath.
# Upstream nativeDeviceSmokeQuantizationscreen; Python3/macOS/iPhone18,4; generated2026-10-06 America/New_York.
# Q4 update2026-10-06: allow explicit q4 and stable opt-in stage profiling; no inference semantics changed. Git diff line map.

# Rescue A hybrid: exact asset hash-gated Validation SPI engine constructor, public synthesize; .q4 ordinary API stays disabled until human gate. No fallback.
